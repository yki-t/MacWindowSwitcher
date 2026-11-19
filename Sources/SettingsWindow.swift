import AppKit
import ServiceManagement

enum SettingsKey {
    static let switchSpace = "SwitchSpace"
    static let moveWindowToSpace = "MoveWindowToSpace"
    // The UUID is stored because a CGDirectDisplayID can change after the
    // display is connected again.
    static let switcherDisplay = "SwitcherDisplay"
    static let switcherDisplayName = "SwitcherDisplayName"
}

private let windowMargin: CGFloat = 20
private let checkBoxSpacing: CGFloat = 10
// The key code of ANSI W. A compare of the characters fails with an input
// source that has no Latin letters.
private let wKey: UInt16 = 13

// An accessory app has no main menu, so no menu item sends Cmd+W to the window.
private final class ClosableWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Caps Lock is in deviceIndependentFlagsMask, so only these four flags are compared.
        // Compare the character first, because Dvorak and AZERTY put W on a
        // different key. Use the key code only when the input source gives a
        // character that is not ASCII.
        let characters = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let isW = characters.allSatisfy(\.isASCII) ? characters == "w" : event.keyCode == wKey
        if event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command, isW {
            performClose(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        performClose(nil)
    }
}

private struct DisplayChoice {
    let uuid: String
    let name: String
}

final class SettingsWindow: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private let loginBox: NSButton
    private let switchSpaceBox: NSButton
    private let moveWindowBox: NSButton
    private let displayPopUp: NSPopUpButton
    private var screenObserver: NSObjectProtocol?

    override init() {
        window = ClosableWindow(
            contentRect: .zero,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: true
        )
        loginBox = NSButton(checkboxWithTitle: "Launch at Login", target: nil, action: nil)
        switchSpaceBox = NSButton(checkboxWithTitle: "Switch Space (Option+H / Option+L)", target: nil, action: nil)
        moveWindowBox = NSButton(checkboxWithTitle: "Move Window to Space (Shift+Option+H / Shift+Option+L)", target: nil, action: nil)
        displayPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
        super.init()

        loginBox.target = self
        loginBox.action = #selector(toggleLaunchAtLogin(_:))
        switchSpaceBox.target = self
        switchSpaceBox.action = #selector(toggleSetting(_:))
        moveWindowBox.target = self
        moveWindowBox.action = #selector(toggleSetting(_:))
        displayPopUp.target = self
        displayPopUp.action = #selector(selectDisplay(_:))
        rebuildDisplayItems()

        let displayRow = NSStackView(views: [NSTextField(labelWithString: "Show switcher on:"), displayPopUp])
        displayRow.orientation = .horizontal

        let stack = NSStackView(views: [loginBox, switchSpaceBox, moveWindowBox, displayRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = checkBoxSpacing
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: windowMargin),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -windowMargin),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: windowMargin),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -windowMargin),
        ])

        window.title = "Settings"
        window.contentView = content
        // Auto Layout makes the window larger at the first layout, but center()
        // uses the size before that layout. Set the size before center().
        // The window is centered only here, so it keeps the position that the
        // user gives it while the app runs.
        window.setContentSize(content.fittingSize)
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.refreshDisplayItems()
        }
    }

    deinit {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
    }

    // The user can change the login item in System Settings, so read the
    // status each time the window opens.
    func show() {
        refresh()
        // An accessory app is not active, so the window opens behind other windows.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    // The user can change the login item in System Settings while this
    // window is open.
    func windowDidBecomeKey(_ notification: Notification) {
        refresh()
    }

    private func refresh() {
        loginBox.state = SMAppService.mainApp.status == .enabled ? .on : .off
        switchSpaceBox.state = UserDefaults.standard.bool(forKey: SettingsKey.switchSpace) ? .on : .off
        moveWindowBox.state = UserDefaults.standard.bool(forKey: SettingsKey.moveWindowToSpace) ? .on : .off
        refreshDisplayItems()
    }

    private func refreshDisplayItems() {
        rebuildDisplayItems()
        // Display names have different lengths, so the window must fit the
        // pop-up again. Keep the top edge where the user put the window.
        guard let content = window.contentView else { return }
        let size = content.fittingSize
        guard size != content.frame.size else { return }
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
        window.setFrame(frame, display: true)
    }

    // addItem(withTitle:) removes an item that has the same title, and two
    // displays of the same model have the same name. Add NSMenuItem objects
    // to the menu and give each title a number when the name occurs again.
    private func rebuildDisplayItems() {
        displayPopUp.removeAllItems()
        let menu = displayPopUp.menu ?? NSMenu()
        displayPopUp.menu = menu
        menu.addItem(NSMenuItem(title: "Display with active window", action: nil, keyEquivalent: ""))
        let stored = UserDefaults.standard.string(forKey: SettingsKey.switcherDisplay)
        var selected: NSMenuItem?
        var nameCounts: [String: Int] = [:]
        for screen in NSScreen.screens {
            guard let uuid = displayUUID(screen) else { continue }
            let name = screen.localizedName
            let count = (nameCounts[name] ?? 0) + 1
            nameCounts[name] = count
            let item = NSMenuItem(title: count == 1 ? name : "\(name) (\(count))", action: nil, keyEquivalent: "")
            item.representedObject = DisplayChoice(uuid: uuid, name: name)
            menu.addItem(item)
            if let stored, stored.caseInsensitiveCompare(uuid) == .orderedSame {
                selected = item
            }
        }
        if let stored, selected == nil {
            let name = UserDefaults.standard.string(forKey: SettingsKey.switcherDisplayName) ?? stored
            let item = NSMenuItem(title: "\(name) (not connected)", action: nil, keyEquivalent: "")
            menu.addItem(item)
            selected = item
        }
        displayPopUp.select(selected ?? menu.item(at: 0))
    }

    @objc private func selectDisplay(_ sender: NSPopUpButton) {
        let defaults = UserDefaults.standard
        if sender.indexOfSelectedItem == 0 {
            defaults.removeObject(forKey: SettingsKey.switcherDisplay)
            defaults.removeObject(forKey: SettingsKey.switcherDisplayName)
        } else if let choice = sender.selectedItem?.representedObject as? DisplayChoice {
            defaults.set(choice.uuid, forKey: SettingsKey.switcherDisplay)
            defaults.set(choice.name, forKey: SettingsKey.switcherDisplayName)
        }
    }

    @objc private func toggleSetting(_ sender: NSButton) {
        let key = sender === switchSpaceBox ? SettingsKey.switchSpace : SettingsKey.moveWindowToSpace
        UserDefaults.standard.set(sender.state == .on, forKey: key)
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSButton) {
        // The click changes the check box state before the call. Show the real
        // status, also when the change fails or needs approval.
        defer { sender.state = SMAppService.mainApp.status == .enabled ? .on : .off }
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
}
