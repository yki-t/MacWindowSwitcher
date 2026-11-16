import AppKit
import ApplicationServices

// Private API. The public Accessibility API does not give the CGWindowID of a
// window, and ScreenCaptureKit identifies a window only by its CGWindowID.
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ id: inout CGWindowID) -> AXError

struct WindowInfo {
    let id: CGWindowID
    let element: AXUIElement
    let app: NSRunningApplication
    let title: String
    let isMinimized: Bool
}

private func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value as? T
}

private func windowID(_ element: AXUIElement) -> CGWindowID? {
    var id: CGWindowID = 0
    guard _AXUIElementGetWindow(element, &id) == .success, id != 0 else { return nil }
    return id
}

final class WindowTracker {
    private var mru: [CGWindowID] = []
    private var observers: [pid_t: AXObserver] = [:]

    init() {
        // The default timeout is 6 s for each call. An application that does
        // not respond must not stop the switcher for that time.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.3)

        seedFromZOrder()
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            observe(app)
        }

        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let self, let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self.observe(app)
            self.bumpFocusedWindow(of: app)
        }
        center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let self, let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            guard let observer = self.observers[app.processIdentifier] else { return }
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
            self.observers.removeValue(forKey: app.processIdentifier)
        }
    }

    func bump(_ id: CGWindowID) {
        mru.removeAll { $0 == id }
        mru.insert(id, at: 0)
    }

    // Only AX calls. It does not use mru or observers, so it can run on a
    // queue other than the main queue.
    func scanWindows() -> [WindowInfo] {
        var windows: [WindowInfo] = []
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            let appElement = AXUIElementCreateApplication(app.processIdentifier)
            guard let elements: [AXUIElement] = attribute(appElement, kAXWindowsAttribute) else { continue }
            for element in elements {
                guard let subrole: String = attribute(element, kAXSubroleAttribute),
                      subrole == kAXStandardWindowSubrole || subrole == kAXDialogSubrole,
                      let id = windowID(element) else { continue }
                let title: String = attribute(element, kAXTitleAttribute) ?? ""
                windows.append(WindowInfo(
                    id: id,
                    element: element,
                    app: app,
                    title: title.isEmpty ? (app.localizedName ?? "") : title,
                    isMinimized: attribute(element, kAXMinimizedAttribute) ?? false
                ))
            }
        }
        return windows
    }

    // Main thread only, because mru is changed on the main thread.
    func sortByMRU(_ windows: [WindowInfo]) -> [WindowInfo] {
        // kAXWindowsAttribute does not return windows on other Desktops, and an
        // application that times out returns no windows. Remove only the IDs of
        // windows that no longer exist, so these windows keep their MRU position.
        if let all = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] {
            let existing = Set(all.compactMap { $0[kCGWindowNumber as String] as? CGWindowID })
            mru.removeAll { !existing.contains($0) }
        }
        let rank = Dictionary(uniqueKeysWithValues: mru.enumerated().map { ($1, $0) })
        return windows.enumerated()
            .sorted { a, b in
                let ra = rank[a.element.id] ?? Int.max, rb = rank[b.element.id] ?? Int.max
                return ra != rb ? ra < rb : a.offset < b.offset
            }
            .map(\.element)
    }

    // The focus history before the start of this process is not available.
    // The front-to-back order of the windows is the nearest substitute.
    private func seedFromZOrder() {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return }
        mru = list
            .filter { ($0[kCGWindowLayer as String] as? Int) == 0 }
            .compactMap { $0[kCGWindowNumber as String] as? CGWindowID }
    }

    private func observe(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard observers[pid] == nil else { return }

        var created: AXObserver?
        let callback: AXObserverCallback = { _, element, _, refcon in
            guard let refcon else { return }
            Unmanaged<WindowTracker>.fromOpaque(refcon).takeUnretainedValue().focusedWindowChanged(element)
        }
        guard AXObserverCreate(pid, callback, &created) == .success, let observer = created else { return }

        let appElement = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        AXObserverAddNotification(observer, appElement, kAXFocusedWindowChangedNotification as CFString, refcon)
        AXObserverAddNotification(observer, appElement, kAXMainWindowChangedNotification as CFString, refcon)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        observers[pid] = observer
    }

    private func focusedWindowChanged(_ element: AXUIElement) {
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        // An application in the background also sends this notification, for
        // example when one of its windows closes. That is not a user focus.
        guard pid == NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let id = windowID(element) else { return }
        bump(id)
    }

    private func bumpFocusedWindow(of app: NSRunningApplication) {
        guard let window = focusedWindow(of: app.processIdentifier),
              let id = windowID(window) else { return }
        bump(id)
    }
}

// Only AX calls, so it can run on any queue. The messaging timeout that
// WindowTracker.init sets also applies here.
func focusedWindow(of pid: pid_t) -> AXUIElement? {
    let appElement = AXUIElementCreateApplication(pid)
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &value) == .success,
          let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    return (value as! AXUIElement)
}
