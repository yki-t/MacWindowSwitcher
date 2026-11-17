import AppKit
import ServiceManagement

enum SettingsKey {
    static let switchSpace = "SwitchSpace"
    static let moveWindowToSpace = "MoveWindowToSpace"
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

final class SettingsWindow: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private let loginBox: NSButton
    private let switchSpaceBox: NSButton
    private let moveWindowBox: NSButton

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
        super.init()

        loginBox.target = self
        loginBox.action = #selector(toggleLaunchAtLogin(_:))
        switchSpaceBox.target = self
        switchSpaceBox.action = #selector(toggleSetting(_:))
        moveWindowBox.target = self
        moveWindowBox.action = #selector(toggleSetting(_:))

        let stack = NSStackView(views: [loginBox, switchSpaceBox, moveWindowBox])
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
