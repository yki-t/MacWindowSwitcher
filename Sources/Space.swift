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

final class SpaceMover {
    private let queue = DispatchQueue(label: "WindowSwitcher.SpaceMover")
    // Read and written on the event tap thread and on the queue. A move
    // request that comes during a move is dropped, so that the user does not
    // get queued moves after the key is released.
    private let moving = OSAllocatedUnfairLock(initialState: false)
    private let connection = CGSMainConnectionID()

    // switchSpace(_:) and moveWindow(_:) are called on the event tap thread.
    // They only add work to the queue.

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
        // The main thread never waits for this queue, so this sync cannot deadlock.
        guard let pid = DispatchQueue.main.sync(execute: { NSWorkspace.shared.frontmostApplication?.processIdentifier }),
              let window = focusedWindow(of: pid) else { return }
        // A full screen window is a Space of its own and has no title bar to hold.
        var fullScreen: CFTypeRef?
        if AXUIElementCopyAttributeValue(window, "AXFullScreen" as CFString, &fullScreen) == .success,
           (fullScreen as? Bool) == true { return }
        var position = CGPoint.zero, size = CGSize.zero
        guard let positionValue = axValue(window, kAXPositionAttribute),
              AXValueGetValue(positionValue, .cgPoint, &position),
              let sizeValue = axValue(window, kAXSizeAttribute),
              AXValueGetValue(sizeValue, .cgSize, &size),
              !isAtEdge(direction) else { return }

        let grab = CGPoint(x: position.x + min(grabOffset.x, size.width / 2), y: position.y + grabOffset.y)
        // Another window can cover the title bar, or the grab point can be off
        // screen. Then the mouse down and the drag go to a different window.
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(grab.x), Float(grab.y), &hit) == .success,
              let hit else { return }
        var hitWindow: CFTypeRef?
        guard CFEqual(hit, window)
            || (AXUIElementCopyAttributeValue(hit, kAXWindowAttribute as CFString, &hitWindow) == .success
                && hitWindow.map { CFEqual($0, window) } == true) else { return }
        guard let source = CGEventSource(stateID: .privateState),
              let cursor = CGEvent(source: nil)?.location else { return }
        let startSpace = CGSGetActiveSpace(connection)

        postMouse(.mouseMoved, at: grab, source: source)
        postMouse(.leftMouseDown, at: grab, source: source)
        // A mouse up must follow the mouse down in all cases, or the system
        // keeps the button down.
        defer {
            postMouse(.leftMouseUp, at: grab, source: source)
            postMouse(.mouseMoved, at: cursor, source: source)
        }
        Thread.sleep(forTimeInterval: grabDelay)
        // The system starts a window drag only after the mouse moves with the
        // button down.
        postMouse(.leftMouseDragged, at: grab, source: source)
        Thread.sleep(forTimeInterval: grabDelay)

        postSwitch(direction)
        let deadline = Date().addingTimeInterval(switchTimeout)
        while CGSGetActiveSpace(connection) == startSpace && Date() < deadline {
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

    // At the first or last Space, the switch does not occur. If the Space list
    // is not available, the mover tries the switch, and the timeout stops the wait.
    private func isAtEdge(_ direction: SpaceDirection) -> Bool {
        guard let displays = CGSCopyManagedDisplaySpaces(connection)?.takeRetainedValue() as? [[String: Any]] else { return false }
        let active = CGSGetActiveSpace(connection)
        for display in displays {
            guard let spaces = display["Spaces"] as? [[String: Any]],
                  let index = spaces.firstIndex(where: { spaceID($0) == active }) else { continue }
            return direction == .left ? index == 0 : index == spaces.count - 1
        }
        return false
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
