import AppKit
import ScreenCaptureKit

final class Thumbnailer {
    private var cache: [CGWindowID: CGImage] = [:]

    func cached(_ id: CGWindowID) -> CGImage? { cache[id] }

    /// `update` runs on the main thread, one time for each captured window.
    func capture(_ windows: [WindowInfo], maxPointSize: CGSize, update: @escaping (CGWindowID, CGImage) -> Void) {
        cache = cache.filter { entry in windows.contains { $0.id == entry.key } }
        // Without the permission, each capture call can show the system
        // permission dialog again.
        guard CGPreflightScreenCaptureAccess() else { return }

        // A minimized or hidden window has no current image. The capture
        // result would replace a good image in the cache with an empty one.
        let wanted = Set(windows.filter { !$0.isMinimized && !$0.app.isHidden }.map(\.id))

        Task {
            guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true) else { return }
            await withTaskGroup(of: Void.self) { group in
                for window in content.windows where wanted.contains(window.windowID) {
                    group.addTask {
                        guard window.frame.width > 0, window.frame.height > 0 else { return }
                        let scale = min(maxPointSize.width / window.frame.width, maxPointSize.height / window.frame.height, 1) * 2
                        let config = SCStreamConfiguration()
                        config.width = max(1, Int(window.frame.width * scale))
                        config.height = max(1, Int(window.frame.height * scale))
                        config.showsCursor = false
                        config.ignoreShadowsSingleWindow = true
                        let filter = SCContentFilter(desktopIndependentWindow: window)
                        guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) else { return }
                        await MainActor.run {
                            self.cache[window.windowID] = image
                            update(window.windowID, image)
                        }
                    }
                }
            }
        }
    }
}
