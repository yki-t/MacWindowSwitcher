import AppKit

private let tileSize = CGSize(width: 240, height: 190)
private let tilePadding: CGFloat = 8
private let headerHeight: CGFloat = 22
private let panelMargin: CGFloat = 16

let thumbnailPointSize = CGSize(
    width: tileSize.width - tilePadding * 2,
    height: tileSize.height - headerHeight - tilePadding * 3
)

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

private final class TileView: NSView {
    private let thumbnailView = NSImageView()
    var onClick: (() -> Void)?

    var isSelected = false {
        didSet {
            layer?.backgroundColor = isSelected
                ? NSColor.controlAccentColor.withAlphaComponent(0.55).cgColor
                : NSColor.clear.cgColor
        }
    }

    init(window: WindowInfo, thumbnail: CGImage?) {
        super.init(frame: CGRect(origin: .zero, size: tileSize))
        wantsLayer = true
        layer?.cornerRadius = 10

        let iconView = NSImageView(frame: CGRect(x: tilePadding, y: tileSize.height - tilePadding - headerHeight + 2, width: 18, height: 18))
        iconView.image = window.app.icon
        addSubview(iconView)

        let titleField = NSTextField(labelWithString: window.title)
        titleField.lineBreakMode = .byTruncatingTail
        titleField.font = .systemFont(ofSize: 12)
        titleField.textColor = .labelColor
        titleField.frame = CGRect(
            x: iconView.frame.maxX + 6,
            y: iconView.frame.minY,
            width: tileSize.width - iconView.frame.maxX - 6 - tilePadding,
            height: 17
        )
        addSubview(titleField)

        thumbnailView.frame = CGRect(origin: CGPoint(x: tilePadding, y: tilePadding), size: thumbnailPointSize)
        thumbnailView.imageScaling = .scaleProportionallyUpOrDown
        thumbnailView.image = window.app.icon
        // A minimized or hidden window keeps the image from the last capture.
        // The lower opacity shows that the window is not on the screen now.
        thumbnailView.alphaValue = window.isMinimized || window.app.isHidden ? 0.5 : 1
        addSubview(thumbnailView)

        if let thumbnail { setThumbnail(thumbnail) }
    }

    required init?(coder: NSCoder) { fatalError() }

    func setThumbnail(_ image: CGImage) {
        thumbnailView.image = NSImage(cgImage: image, size: .zero)
    }

    // The panel does not become the key window, so the first click must
    // reach the tile.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // The window sends mouse events to the deepest view that the hit test
    // returns. Return the tile for all points in it, so that the subviews do
    // not get the clicks.
    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }

    override func mouseDown(with event: NSEvent) { onClick?() }
}

final class SwitcherPanel {
    private let panel: NSPanel
    private let container = FlippedView()
    private var tiles: [CGWindowID: TileView] = [:]
    private var order: [CGWindowID] = []
    var onClick: ((Int) -> Void)?

    init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        // The status item menu can make this app active. When the app then
        // becomes inactive, AppKit must not hide the panel while it is in use.
        panel.hidesOnDeactivate = false

        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 16
        background.layer?.masksToBounds = true
        panel.contentView = background

        container.autoresizingMask = [.width, .height]
        background.addSubview(container)
    }

    func show(_ windows: [WindowInfo], selected: Int, thumbnail: (CGWindowID) -> CGImage?) {
        container.subviews.forEach { $0.removeFromSuperview() }
        tiles.removeAll()
        order = windows.map(\.id)

        let screen = UserDefaults.standard.string(forKey: SettingsKey.switcherDisplay).flatMap(connectedScreen(uuid:))
            ?? NSScreen.main ?? NSScreen.screens[0]
        let available = CGSize(
            width: screen.visibleFrame.width * 0.9 - panelMargin * 2,
            height: screen.visibleFrame.height * 0.9 - panelMargin * 2
        )
        let maxColumns = max(1, Int(available.width / tileSize.width))
        var columns = min(windows.count, maxColumns)
        var scale: CGFloat = 1
        func rowCount(_ columns: Int) -> Int { (windows.count + columns - 1) / columns }
        if CGFloat(columns) * tileSize.width > available.width
            || CGFloat(rowCount(columns)) * tileSize.height > available.height {
            // A borderless window is not kept inside the screen. Use the
            // column count that keeps the tiles largest.
            scale = 0
            for candidate in 1...max(1, windows.count) {
                let fit = min(
                    1,
                    available.width / (CGFloat(candidate) * tileSize.width),
                    available.height / (CGFloat(rowCount(candidate)) * tileSize.height)
                )
                if fit > scale {
                    scale = fit
                    columns = candidate
                }
            }
        }
        let rows = rowCount(columns)
        let cellSize = CGSize(width: tileSize.width * scale, height: tileSize.height * scale)

        for (index, window) in windows.enumerated() {
            let tile = TileView(window: window, thumbnail: thumbnail(window.id))
            tile.frame = CGRect(
                x: panelMargin + CGFloat(index % columns) * cellSize.width,
                y: panelMargin + CGFloat(index / columns) * cellSize.height,
                width: cellSize.width,
                height: cellSize.height
            )
            // The bounds stay at the full tile size, so the layout in TileView
            // does not change. For a layer-backed view, AppKit applies the
            // frame-to-bounds ratio as a transform on the layer. So the
            // background and the corner radius get the same scale.
            tile.bounds.size = tileSize
            tile.onClick = { [weak self] in self?.onClick?(index) }
            container.addSubview(tile)
            tiles[window.id] = tile
        }

        let size = CGSize(
            width: CGFloat(columns) * cellSize.width + panelMargin * 2,
            height: CGFloat(rows) * cellSize.height + panelMargin * 2
        )
        let origin = CGPoint(x: screen.frame.midX - size.width / 2, y: screen.frame.midY - size.height / 2)
        panel.setFrame(CGRect(origin: origin, size: size), display: true)
        container.frame = CGRect(origin: .zero, size: size)

        select(selected)
        panel.orderFrontRegardless()
    }

    func select(_ index: Int) {
        for (i, id) in order.enumerated() {
            tiles[id]?.isSelected = i == index
        }
    }

    func setThumbnail(_ image: CGImage, for id: CGWindowID) {
        tiles[id]?.setThumbnail(image)
    }

    func hide() {
        panel.orderOut(nil)
    }
}
