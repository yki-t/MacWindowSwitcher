import AppKit
import ApplicationServices

// Public API, but deprecated. The SDK marks it unavailable in Swift, and
// _SLPSSetFrontProcessWithOptions and SLPSPostEventRecordTo need a PSN.
@_silgen_name("GetProcessForPID")
private func GetProcessForPID(_ pid: pid_t, _ psn: inout ProcessSerialNumber) -> OSStatus

// Private API. Activation of the app brings all of its windows to the front.
// With a window ID, this call brings only that window to the front.
@_silgen_name("_SLPSSetFrontProcessWithOptions")
private func _SLPSSetFrontProcessWithOptions(_ psn: inout ProcessSerialNumber, _ wid: CGWindowID, _ mode: UInt32) -> CGError

// Private API. Without the activation of the app, the window does not become
// key. yabai sends this event record to make the window key.
@_silgen_name("SLPSPostEventRecordTo")
private func SLPSPostEventRecordTo(_ psn: inout ProcessSerialNumber, _ bytes: UnsafeMutablePointer<UInt8>) -> CGError

// Mode value that marks the change of the front process as user generated.
private let userGeneratedMode: UInt32 = 0x200

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
        AXUIElementSetAttributeValue(window.element, kAXMainAttribute as CFString, kCFBooleanTrue)
        var psn = ProcessSerialNumber()
        guard GetProcessForPID(window.app.processIdentifier, &psn) == noErr else { return }
        _ = _SLPSSetFrontProcessWithOptions(&psn, window.id, userGeneratedMode)
        makeKeyWindow(&psn, window.id)
        AXUIElementPerformAction(window.element, kAXRaiseAction as CFString)
    }

    // The record layout comes from yabai (window_manager_make_key_window).
    // The fields are not documented.
    private func makeKeyWindow(_ psn: inout ProcessSerialNumber, _ id: CGWindowID) {
        var bytes = [UInt8](repeating: 0, count: 0xf8)
        bytes[0x04] = 0xf8
        bytes[0x3a] = 0x10
        withUnsafeBytes(of: id) { bytes.replaceSubrange(0x3c..<0x3c + $0.count, with: $0) }
        bytes.replaceSubrange(0x20..<0x30, with: repeatElement(0xff, count: 0x10))
        for type: UInt8 in [0x01, 0x02] {
            bytes[0x08] = type
            _ = SLPSPostEventRecordTo(&psn, &bytes)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var trustTimer: Timer?
    private var signalSources: [DispatchSourceSignal] = []
    private var switcher: Switcher?
    private var spaceMover: SpaceMover?
    private var settingsWindow: SettingsWindow?
    private var hotKey: HotKey?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "rectangle.on.rectangle", accessibilityDescription: nil)
        let menu = NSMenu()
        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(openSettings(_:)), keyEquivalent: "")
        settingsItem.target = self
        menu.addItem(settingsItem)
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
        spaceMover?.releaseMouse()
    }

    @objc private func openSettings(_ sender: NSMenuItem) {
        let window = settingsWindow ?? SettingsWindow()
        settingsWindow = window
        window.show()
    }

    private func start() {
        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
        }
        let switcher = Switcher()
        let spaceMover = SpaceMover()
        guard let hotKey = HotKey(switcher: switcher, spaceMover: spaceMover) else {
            FileHandle.standardError.write("WindowSwitcher: cannot create the event tap\n".data(using: .utf8)!)
            NSApp.terminate(nil)
            return
        }
        self.switcher = switcher
        self.spaceMover = spaceMover
        self.hotKey = hotKey
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
