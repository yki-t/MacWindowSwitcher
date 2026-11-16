import AppKit
import ServiceManagement

enum SettingsKey {
    static let switchSpace = "SwitchSpace"
    static let moveWindowToSpace = "MoveWindowToSpace"
}

final class SettingsWindow: NSObject {
    private let window: NSWindow
    private let loginBox: NSButton
    private let switchSpaceBox: NSButton
    private let moveWindowBox: NSButton

    override init() {
        window = NSWindow(
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
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
        ])

        window.title = "Settings"
        window.contentView = content
        // The window is created with a zero content rect. If the window keeps
        // that size, AppKit gives it a default width that is too narrow for the
        // longest title, and the stack view compresses that check box.
        window.setContentSize(content.fittingSize)
        window.isReleasedWhenClosed = false
    }

    // The user can change the login item in System Settings, so read the
    // status each time the window opens.
    func show() {
        refresh()
        // An accessory app is not active, so the window opens behind other windows.
        NSApp.activate(ignoringOtherApps: true)
        if !window.isVisible { window.center() }
        window.makeKeyAndOrderFront(nil)
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
