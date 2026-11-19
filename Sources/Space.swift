import AppKit
import ApplicationServices
import os

// Private API. The public API does not tell which Space is active, so the
// mover cannot otherwise know when a Space switch is complete.
@_silgen_name("CGSMainConnectionID")
private func CGSMainConnectionID() -> Int32

@_silgen_name("CGSGetActiveSpace")
private func CGSGetActiveSpace(_ connection: Int32) -> UInt64

@_silgen_name("CGSCopyManagedDisplaySpaces")
private func CGSCopyManagedDisplaySpaces(_ connection: Int32) -> Unmanaged<CFArray>?

// The event tap gets the events that the mover posts. This value in
// eventSourceUserData lets the tap pass them through.
let spaceMoverEventMarker: Int64 = 0x5753_5350

private let leftArrowKey: CGKeyCode = 123
private let rightArrowKey: CGKeyCode = 124
// The modifier flags of the system symbolic hot keys 79 and 81
// (Move left / right a space): 0x840000.
private let switchFlags: CGEventFlags = [.maskControl, .maskSecondaryFn]
// Below the top edge of the window, in the title bar. The x offset is to the
// right of the close, minimize and zoom buttons.
private let grabOffset = CGPoint(x: 100, y: 5)
private let pollInterval: TimeInterval = 0.02
private let switchTimeout: TimeInterval = 1.0
// The active Space ID changes before the switch animation ends. A mouse up
// during the animation can drop the window on the old Space.
private let settleDelay: TimeInterval = 0.15
private let grabDelay: TimeInterval = 0.05

enum SpaceDirection {
    case left, right
}

private struct MouseState {
    var grab: CGPoint?
    // The cursor position before the mouse down. releaseMouse() moves the
    // cursor back to it, because the process can exit before the defer in
    // moveOnQueue(_:) runs.
    var cursor: CGPoint?
    var terminating = false
}

final class SpaceMover {
    private let queue = DispatchQueue(label: "WindowSwitcher.SpaceMover")
    // Read and written on the event tap thread and on the queue. A move
    // request that comes during a move is dropped, so that the user does not
    // get queued moves after the key is released. A switch request during a
    // move is also dropped, because a Space change in the move changes the
    // Space that gets the window.
    private let moving = OSAllocatedUnfairLock(initialState: false)
    // grab is the point of the mouse down while the button is down. The main
    // thread reads it at termination. The mouse down, the drag and each mouse
    // up are posted while this lock is held, so that the order of the queue
    // and the termination is set by the lock: no mouse down after
    // termination, no drag after the mouse up, and one mouse up for each
    // mouse down. Do not take moving in this lock.
    private let mouseState = OSAllocatedUnfairLock(initialState: MouseState())
    private let connection = CGSMainConnectionID()

    // switchSpace(_:) and moveWindow(_:) are called on the event tap thread.
    // They only add work to the queue.

    // Called on the main thread at termination. It must not wait for the
    // queue, because moveOnQueue(_:) waits for the main thread. Without this
    // mouse up, the system keeps the button down after the process exits.
    func releaseMouse() {
        mouseState.withLock { state in
            state.terminating = true
            guard let point = state.grab,
                  let source = CGEventSource(stateID: .privateState) else { return }
            postMouse(.leftMouseUp, at: point, source: source)
            state.grab = nil
            if let cursor = state.cursor {
                postMouse(.mouseMoved, at: cursor, source: source)
                state.cursor = nil
            }
        }
    }

    func switchSpace(_ direction: SpaceDirection) {
        if moving.withLock({ $0 }) { return }
        queue.async { self.postSwitch(direction) }
    }

    func moveWindow(_ direction: SpaceDirection) {
        let claimed = moving.withLock { busy -> Bool in
            guard !busy else { return false }
            busy = true
            return true
        }
        guard claimed else { return }
        queue.async {
            defer { self.moving.withLock { $0 = false } }
            self.moveOnQueue(direction)
        }
    }

    // A private source has its own modifier state. With a shared source, the
    // Option and Shift keys that the user holds can be added to the event, and
    // the system then does not see the symbolic hot key.
    private func postSwitch(_ direction: SpaceDirection) {
        guard let source = CGEventSource(stateID: .privateState) else { return }
        let key = direction == .left ? leftArrowKey : rightArrowKey
        for isDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: isDown) else { return }
            event.flags = switchFlags
            event.setIntegerValueField(.eventSourceUserData, value: spaceMoverEventMarker)
            event.post(tap: .cghidEventTap)
        }
    }

    // The public API cannot move a window to another Space. The mover holds
    // the window by its title bar while the Space switches, as a user drag does.
    private func moveOnQueue(_ direction: SpaceDirection) {
        // The main thread waits for this queue only for the short mouseState
        // lock, and that lock does not wait for the main thread. So this sync
        // cannot deadlock.
        guard let pid = DispatchQueue.main.sync(execute: { NSWorkspace.shared.frontmostApplication?.processIdentifier }),
              let window = focusedWindow(of: pid) else { return }
        // A full screen window is a Space of its own and has no title bar to hold.
        if (attribute(window, "AXFullScreen") as Bool?) == true { return }
        var position = CGPoint.zero, size = CGSize.zero
        guard let positionValue = axValue(window, kAXPositionAttribute),
              AXValueGetValue(positionValue, .cgPoint, &position),
              let sizeValue = axValue(window, kAXSizeAttribute),
              AXValueGetValue(sizeValue, .cgSize, &size) else { return }

        let grab = CGPoint(x: position.x + min(grabOffset.x, size.width / 2), y: position.y + grabOffset.y)
        let display = displayWithSpaces(at: grab)
        guard !isAtEdge(direction, on: display) else { return }
        // Another window can cover the title bar, or the grab point can be off
        // screen. Then the mouse down and the drag go to a different window.
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(grab.x), Float(grab.y), &hit) == .success,
              let hit else { return }
        guard CFEqual(hit, window)
            || (attribute(hit, kAXWindowAttribute) as AXUIElement?).map({ CFEqual($0, window) }) == true else { return }
        guard let source = CGEventSource(stateID: .privateState),
              let cursor = CGEvent(source: nil)?.location,
              let startSpace = currentSpace(on: display) else { return }

        postMouse(.mouseMoved, at: grab, source: source)
        let pressed = mouseState.withLock { state -> Bool in
            guard !state.terminating else { return false }
            state.grab = grab
            state.cursor = cursor
            postMouse(.leftMouseDown, at: grab, source: source)
            return true
        }
        guard pressed else {
            postMouse(.mouseMoved, at: cursor, source: source)
            return
        }
        // A mouse up must follow the mouse down in all cases, or the system
        // keeps the button down. releaseMouse() can send it first.
        defer {
            mouseState.withLock { state in
                guard state.grab != nil else { return }
                postMouse(.leftMouseUp, at: grab, source: source)
                state.grab = nil
                state.cursor = nil
            }
            postMouse(.mouseMoved, at: cursor, source: source)
        }
        Thread.sleep(forTimeInterval: grabDelay)
        // The system starts a window drag only after the mouse moves with the
        // button down.
        mouseState.withLock { state in
            guard state.grab != nil else { return }
            postMouse(.leftMouseDragged, at: grab, source: source)
        }
        Thread.sleep(forTimeInterval: grabDelay)

        postSwitch(direction)
        let deadline = Date().addingTimeInterval(switchTimeout)
        while (currentSpace(on: display) ?? startSpace) == startSpace && Date() < deadline {
            Thread.sleep(forTimeInterval: pollInterval)
        }
        Thread.sleep(forTimeInterval: settleDelay)
    }

    private func postMouse(_ type: CGEventType, at point: CGPoint, source: CGEventSource) {
        guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left) else { return }
        // The user holds Shift and Option. With these flags, a click can do a
        // different action in the application.
        event.flags = []
        event.setIntegerValueField(.eventSourceUserData, value: spaceMoverEventMarker)
        event.post(tap: .cghidEventTap)
    }

    // At the first or last Space, the switch does not occur. A window cannot
    // be dropped on the Space of a full screen app (type 4). If the Space list
    // is not available, the mover tries the switch, and the timeout stops the wait.
    private func isAtEdge(_ direction: SpaceDirection, on display: CGDirectDisplayID?) -> Bool {
        guard let entries = CGSCopyManagedDisplaySpaces(connection)?.takeRetainedValue() as? [[String: Any]] else { return false }
        let current: UInt64
        let candidates: [[String: Any]]
        if let display, let found = currentSpaceEntry(of: display, in: entries) {
            current = found.space
            candidates = [found.entry]
        } else {
            current = CGSGetActiveSpace(connection)
            candidates = entries
        }
        for entry in candidates {
            guard let spaces = entry["Spaces"] as? [[String: Any]],
                  let index = spaces.firstIndex(where: { spaceID($0) == current }) else { continue }
            let next = direction == .left ? index - 1 : index + 1
            guard spaces.indices.contains(next) else { return true }
            return (spaces[next]["type"] as? NSNumber)?.intValue == 4
        }
        return false
    }

    // With "Displays have separate Spaces" on, each display has its own
    // current Space, and the active Space can change when the cursor goes to
    // another display. The mover then reads the Space of the display that has
    // the grab point. With one display, when the point is not on exactly one
    // display, or when no entry matches the display, it returns nil and the
    // mover uses the active Space.
    private func displayWithSpaces(at point: CGPoint) -> CGDirectDisplayID? {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 1 else { return nil }
        var display: CGDirectDisplayID = 0
        guard CGGetDisplaysWithPoint(point, 1, &display, &count) == .success, count == 1,
              let entries = CGSCopyManagedDisplaySpaces(connection)?.takeRetainedValue() as? [[String: Any]],
              currentSpaceEntry(of: display, in: entries) != nil else { return nil }
        return display
    }

    // With a display, nil means that the Space list does not have it now.
    // The active Space comes from a different source than the entry of the
    // display, so it must not replace the entry value in a comparison.
    private func currentSpace(on display: CGDirectDisplayID?) -> UInt64? {
        guard let display else { return CGSGetActiveSpace(connection) }
        guard let entries = CGSCopyManagedDisplaySpaces(connection)?.takeRetainedValue() as? [[String: Any]] else { return nil }
        return currentSpaceEntry(of: display, in: entries)?.space
    }

    private func currentSpaceEntry(of display: CGDirectDisplayID, in entries: [[String: Any]]) -> (entry: [String: Any], space: UInt64)? {
        guard let entry = entries.first(where: { matches($0, display) }),
              let space = (entry["Current Space"] as? [String: Any]).flatMap(spaceID) else { return nil }
        return (entry, space)
    }

    // The identifier is a UUID string. When "Displays have separate Spaces"
    // is off in System Settings, all displays share one entry with the
    // identifier "Main", and all displays show the same Space. Only the main
    // display matches that entry. For a grab on a different display, the
    // mover uses the active Space.
    private func matches(_ entry: [String: Any], _ display: CGDirectDisplayID) -> Bool {
        guard let identifier = entry["Display Identifier"] as? String else { return false }
        if identifier == "Main" { return CGDisplayIsMain(display) != 0 }
        guard let text = displayUUID(display) else { return false }
        return identifier.caseInsensitiveCompare(text) == .orderedSame
    }

    private func spaceID(_ space: [String: Any]) -> UInt64? {
        (space["ManagedSpaceID"] as? NSNumber)?.uint64Value ?? (space["id64"] as? NSNumber)?.uint64Value
    }

    private func axValue(_ element: AXUIElement, _ name: String) -> AXValue? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        return (value as! AXValue)
    }
}
