import AppKit

// Private API. Symbolic hot key 1 is Cmd+Tab and 2 is Cmd+Shift+Tab. While
// they are enabled, the system switcher gets the keys before the event tap.
@_silgen_name("CGSSetSymbolicHotKeyEnabled")
func CGSSetSymbolicHotKeyEnabled(_ hotKey: Int32, _ enabled: Bool) -> CGError

private let tabKey: Int64 = 48
private let escapeKey: Int64 = 53
private let leftKey: Int64 = 123
private let rightKey: Int64 = 124
private let hKey: Int64 = 4
private let lKey: Int64 = 37

final class HotKey {
    private weak var switcher: Switcher?
    private weak var spaceMover: SpaceMover?
    private var tap: CFMachPort?
    private var engaged = false
    // Key codes of the Option+H / L key downs that the tap stopped. The
    // frontmost application must not get a key up without its key down.
    // Read and written only on the tap thread, in handle(_:_:).
    private var stoppedKeys: Set<Int64> = []

    init?(switcher: Switcher, spaceMover: SpaceMover) {
        self.switcher = switcher
        self.spaceMover = spaceMover

        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let hotKey = Unmanaged<HotKey>.fromOpaque(refcon).takeUnretainedValue()
            return hotKey.handle(type, event)
        }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return nil }
        self.tap = tap

        // The tap is an active filter, so all keyboard input of the session
        // waits for the callback. AX calls on the main thread can block it for
        // up to 0.3 s each, so the tap uses its own run loop.
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        let thread = Thread {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CFRunLoopRun()
        }
        thread.name = "WindowSwitcher.HotKey"
        thread.qualityOfService = .userInteractive
        thread.start()

        // Without the tap, a disabled Cmd+Tab would leave the user with no switcher.
        _ = CGSSetSymbolicHotKeyEnabled(1, false)
        _ = CGSSetSymbolicHotKeyEnabled(2, false)
    }

    func restoreNativeHotKeys() {
        _ = CGSSetSymbolicHotKeyEnabled(1, true)
        _ = CGSSetSymbolicHotKeyEnabled(2, true)
    }

    // All keyboard input of the session waits until this function returns.
    // The Switcher methods only add work to the Switcher queue, and the
    // SpaceMover methods only take a lock and add work to the SpaceMover
    // queue, so it returns fast. Switcher state is not read here, because it
    // is changed on the Switcher queue.
    // engaged is read and written only on the tap thread, in this function.
    // It is true from Cmd+Tab until the Cmd release or Esc.
    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        guard let switcher else { return pass }

        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            // A key up that occurs while the tap is disabled does not come
            // later. A stale key code would stop the key up of a later key press.
            stoppedKeys.removeAll()
            // The tap does not get the Cmd release if it occurs while the tap
            // is disabled, so the current flags tell if Cmd is still down.
            if engaged && !CGEventSource.flagsState(.combinedSessionState).contains(.maskCommand) {
                engaged = false
                switcher.commit()
            }
            return pass

        case .flagsChanged:
            if engaged && !event.flags.contains(.maskCommand) {
                engaged = false
                switcher.commit()
            }
            return pass

        case .keyDown:
            // The Ctrl+Left / Right arrow events that SpaceMover posts must go
            // to the system. With the panel open, the arrow keys move the selection.
            if event.getIntegerValueField(.eventSourceUserData) == spaceMoverEventMarker { return pass }
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            let flags = event.flags
            // A key down that the tap passes also has a key up that it must pass.
            stoppedKeys.remove(keyCode)
            if !engaged, keyCode == hKey || keyCode == lKey,
               flags.contains(.maskAlternate), !flags.contains(.maskCommand), !flags.contains(.maskControl),
               let spaceMover {
                let direction: SpaceDirection = keyCode == hKey ? .left : .right
                // UserDefaults is thread safe, and a read here sees a change
                // in the settings window without a restart.
                if flags.contains(.maskShift) {
                    guard UserDefaults.standard.bool(forKey: SettingsKey.moveWindowToSpace) else { return pass }
                    // A move takes up to about 1 s. A key repeat would start
                    // more moves after the user releases the key.
                    if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
                        spaceMover.moveWindow(direction)
                    }
                } else {
                    guard UserDefaults.standard.bool(forKey: SettingsKey.switchSpace) else { return pass }
                    spaceMover.switchSpace(direction)
                }
                stoppedKeys.insert(keyCode)
                return nil
            }
            if keyCode == tabKey && flags.contains(.maskCommand)
                && !flags.contains(.maskControl) && !flags.contains(.maskAlternate) {
                engaged = true
                if flags.contains(.maskShift) { switcher.previous() } else { switcher.next() }
                return nil
            }
            guard engaged else { return pass }
            switch keyCode {
            case escapeKey:
                engaged = false
                switcher.cancel()
            case leftKey: switcher.step(by: -1)
            case rightKey: switcher.step(by: 1)
            default: break
            }
            // Cmd is down while engaged. Other keys would go to the frontmost
            // application as shortcuts such as Cmd+W.
            return nil

        case .keyUp:
            if event.getIntegerValueField(.eventSourceUserData) == spaceMoverEventMarker { return pass }
            // The key up has no Option flag when the user releases Option
            // first, so only the key code is compared.
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            return stoppedKeys.remove(keyCode) != nil ? nil : pass

        default:
            return pass
        }
    }
}
