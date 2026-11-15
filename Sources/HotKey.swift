import AppKit

// Private API. Symbolic hot key 1 is Cmd+Tab and 2 is Cmd+Shift+Tab. While
// they are enabled, the system switcher gets the keys before the event tap.
@_silgen_name("CGSSetSymbolicHotKeyEnabled")
func CGSSetSymbolicHotKeyEnabled(_ hotKey: Int32, _ enabled: Bool) -> CGError

private let tabKey: Int64 = 48
private let escapeKey: Int64 = 53
private let leftKey: Int64 = 123
private let rightKey: Int64 = 124

final class HotKey {
    private weak var switcher: Switcher?
    private var tap: CFMachPort?
    private var engaged = false

    init?(switcher: Switcher) {
        self.switcher = switcher

        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
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
    // The Switcher methods only add work to the Switcher queue, so it returns
    // fast. Switcher state is not read here, because it is changed on the
    // Switcher queue.
    // engaged is read and written only on the tap thread, in this function.
    // It is true from Cmd+Tab until the Cmd release or Esc.
    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        guard let switcher else { return pass }

        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
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
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            let flags = event.flags
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

        default:
            return pass
        }
    }
}
