import AppKit
import ApplicationServices
import ServiceManagement

final class Switcher {
    private let tracker = WindowTracker()
    private let thumbnailer = Thumbnailer()
    private let panel = SwitcherPanel()
    // AX calls can block for up to the messaging timeout for each call. They
    // run here, so that the event tap thread does not wait.
    // isActive, windows and selected are used only on this queue.
    private let queue = DispatchQueue(label: "WindowSwitcher.Switcher")
    private var isActive = false
    private var windows: [WindowInfo] = []
    private var selected = 0

    init() {
        panel.onClick = { [weak self] index in
            self?.queue.async {
                guard let self, self.isActive, self.windows.indices.contains(index) else { return }
                self.selected = index
                self.commitOnQueue()
            }
        }
    }

    // next(), previous(), step(by:), commit() and cancel() are called on the
    // event tap thread. They use only the queue before queue.async, so they are
    // safe from any thread. The serial queue keeps their order, so a commit
    // runs after the open.

    func next() {
        queue.async {
            if !self.isActive {
                self.open { $0 > 1 ? 1 : 0 }
            } else {
                self.move(by: 1)
            }
        }
    }

    func previous() {
        queue.async {
            if !self.isActive {
                self.open { $0 - 1 }
            } else {
                self.move(by: -1)
            }
        }
    }

    // The arrow keys must not open the panel. The tap stays engaged after a
    // click commit or after an open that found no windows. An open there
    // would cause a switch at the Cmd release that the user did not request.
    func step(by delta: Int) {
        queue.async {
            guard self.isActive else { return }
            self.move(by: delta)
        }
    }

    private func move(by delta: Int) {
        let count = windows.count
        selected = ((selected + delta) % count + count) % count
        showSelection()
    }

    func commit() {
        queue.async { self.commitOnQueue() }
    }

    func cancel() {
        queue.async {
            self.isActive = false
            DispatchQueue.main.async { self.panel.hide() }
        }
    }

    private func showSelection() {
        let index = selected
        DispatchQueue.main.async { self.panel.select(index) }
    }

    private func commitOnQueue() {
        guard isActive else { return }
        isActive = false
        let window = windows[selected]
        DispatchQueue.main.async {
            self.panel.hide()
            self.tracker.bump(window.id)
        }
        focus(window)
    }

    private func open(selecting initial: (Int) -> Int) {
        let scanned = tracker.scanWindows()
        // The main thread never waits for this queue, so this sync cannot deadlock.
        let ordered = DispatchQueue.main.sync { tracker.sortByMRU(scanned) }
        guard !ordered.isEmpty else { return }
        windows = ordered
        selected = initial(ordered.count)
        isActive = true
        let index = selected
        DispatchQueue.main.async { [self] in
            self.panel.show(ordered, selected: index, thumbnail: self.thumbnailer.cached)
            self.thumbnailer.capture(ordered, maxPointSize: thumbnailPointSize) { [weak self] id, image in
                self?.panel.setThumbnail(image, for: id)
            }
        }
    }

    private func focus(_ window: WindowInfo) {
        if window.app.isHidden { window.app.unhide() }
        if window.isMinimized {
            AXUIElementSetAttributeValue(window.element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }
        AXUIElementPerformAction(window.element, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(window.element, kAXMainAttribute as CFString, kCFBooleanTrue)
        let appElement = AXUIElementCreateApplication(window.app.processIdentifier)
        AXUIElementSetAttributeValue(appElement, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        window.app.activate(options: [])
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var statusItem: NSStatusItem?
    private var trustTimer: Timer?
    private var signalSources: [DispatchSourceSignal] = []
    private var switcher: Switcher?
    private var hotKey: HotKey?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "rectangle.on.rectangle", accessibilityDescription: nil)
        let menu = NSMenu()
        let loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin(_:)), keyEquivalent: "")
        loginItem.target = self
        menu.addItem(loginItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: ""))
        item.menu = menu
        statusItem = item

        // A kill from `make install` must go through applicationWillTerminate,
        // or Cmd+Tab stays disabled for the whole login session.
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { NSApp.terminate(nil) }
            source.resume()
            signalSources.append(source)
        }

        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if AXIsProcessTrustedWithOptions(options) {
            start()
        } else {
            trustTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
                guard AXIsProcessTrusted() else { return }
                timer.invalidate()
                self?.trustTimer = nil
                self?.start()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotKey?.restoreNativeHotKeys()
    }

    // AppKit validates menu items each time the menu opens. The user can
    // change the login item in System Settings, so read the status here.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleLaunchAtLogin(_:)) {
            menuItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        }
        return true
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        do {
            switch SMAppService.mainApp.status {
            case .enabled:
                try SMAppService.mainApp.unregister()
            case .requiresApproval:
                // The item is registered, but the user must allow it in System
                // Settings (for example, the user turned it off there). register()
                // always fails in this status, and only the user can allow it.
                SMAppService.openSystemSettingsLoginItems()
            case .notRegistered, .notFound:
                // The status .notFound does not tell if register() can succeed.
                // Try it; the alert below shows a failure.
                try SMAppService.mainApp.register()
            @unknown default:
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Cannot change Launch at Login"
            alert.informativeText = error.localizedDescription
            // An accessory app is not active, so the alert opens behind other windows.
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    private func start() {
        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
        }
        let switcher = Switcher()
        guard let hotKey = HotKey(switcher: switcher) else {
            FileHandle.standardError.write("WindowSwitcher: cannot create the event tap\n".data(using: .utf8)!)
            NSApp.terminate(nil)
            return
        }
        self.switcher = switcher
        self.hotKey = hotKey
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
