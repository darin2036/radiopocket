#if os(macOS)
import AppKit
import AVFoundation

/// Menu bar and Dock hiding is app-wide: set when the first full-screen window opens, restored when the last one closes.
enum FullScreenPresentation {
    private static var count = 0
    private static var saved: NSApplication.PresentationOptions = []
    static func enter() {
        if count == 0 { saved = NSApp.presentationOptions }
        count += 1
        NSApp.presentationOptions = [.autoHideMenuBar, .autoHideDock]
    }
    static func leave() {
        count = max(0, count - 1)
        if count == 0 { NSApp.presentationOptions = saved }
    }
}

/// One channel in the multiview wall. It draws the engine's player in its own layer, so the panel's window can stay hidden.
private final class MultiviewTile: NSView {
    private let playerLayer = AVPlayerLayer()
    private let badge = NSButton()
    private let caption = NSTextField(labelWithString: "")
    private var hovering = false
    var onClick: (() -> Void)?
    var audible = false { didSet { refresh() } }
    var name = "" { didSet { caption.stringValue = name } }

    init(player: AVPlayer) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.borderColor = NSColor.systemTeal.cgColor
        playerLayer.player = player; playerLayer.videoGravity = .resizeAspect
        layer?.addSublayer(playerLayer)
        badge.isBordered = false; badge.isEnabled = false
        badge.wantsLayer = true; badge.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor; badge.layer?.cornerRadius = 4
        badge.contentTintColor = .white
        addSubview(badge)
        caption.font = .systemFont(ofSize: 12, weight: .semibold); caption.textColor = .white
        caption.wantsLayer = true; caption.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor; caption.layer?.cornerRadius = 4
        caption.lineBreakMode = .byTruncatingTail
        addSubview(caption)
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func refresh() {
        layer?.borderWidth = audible ? 3 : 0
        badge.image = NSImage(systemSymbolName: audible ? "speaker.wave.2.fill" : "speaker.slash.fill", accessibilityDescription: audible ? "Audio from this panel" : "Play audio from this panel")
        badge.isHidden = !(audible || hovering)
        caption.isHidden = !hovering
        needsLayout = true
    }
    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
        badge.frame = NSRect(x: bounds.maxX - 34, y: bounds.maxY - 32, width: 26, height: 24)
        let width = min(bounds.width - 60, caption.intrinsicContentSize.width + 12)
        caption.frame = NSRect(x: 8, y: bounds.maxY - 30, width: max(0, width), height: 22)
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; refresh() }
    override func mouseExited(with event: NSEvent) { hovering = false; refresh() }
    override func mouseDown(with event: NSEvent) { onClick?() }
}

private final class MultiviewWindow: NSWindow {
    var onEscape: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func keyDown(with event: NSEvent) { if event.keyCode == 53 { onEscape?() } else { super.keyDown(with: event) } }
}

private final class MultiviewWall: NSView {
    var tiles: [MultiviewTile] = [] { didSet { oldValue.forEach { $0.removeFromSuperview() }; tiles.forEach(addSubview); needsLayout = true } }
    static let gap: CGFloat = 4
    /// The grid whose 16:9 pictures come out largest on this screen.
    static func grid(count: Int, in size: NSSize) -> (columns: Int, rows: Int) {
        var best = (columns: 1, rows: count), area: CGFloat = 0
        for columns in 1...max(1, count) {
            let rows = (count + columns - 1) / columns
            let cellW = size.width / CGFloat(columns), cellH = size.height / CGFloat(rows)
            let width = min(cellW, cellH * 16 / 9)
            if width * width > area { area = width * width; best = (columns, rows) }
        }
        return best
    }
    override func layout() {
        super.layout()
        guard !tiles.isEmpty else { return }
        let (columns, rows) = Self.grid(count: tiles.count, in: bounds.size)
        let gap = Self.gap
        let cellW = (bounds.width - gap * CGFloat(columns - 1)) / CGFloat(columns)
        let cellH = (bounds.height - gap * CGFloat(rows - 1)) / CGFloat(rows)
        for (index, tile) in tiles.enumerated() {
            let row = index / columns, column = index % columns
            // A short last row is centered.
            let inRow = row == rows - 1 ? tiles.count - row * columns : columns
            let indent = CGFloat(columns - inRow) * (cellW + gap) / 2
            tile.frame = NSRect(x: indent + CGFloat(column) * (cellW + gap), y: bounds.height - CGFloat(row + 1) * cellH - CGFloat(row) * gap, width: cellW, height: cellH)
        }
    }
}

/// Every open video panel arranged on one screen, like a multicast wall. Click a picture to move the audio to it; Esc leaves.
final class MultiviewController {
    private let window: MultiviewWindow
    private let wall = MultiviewWall()
    private var tiles: [(engine: RadioEngine, tile: MultiviewTile)] = []
    var onTakeAudio: ((RadioEngine) -> Void)?
    var onExit: (() -> Void)?
    private var closed = false

    init(panels: [(name: String, engine: RadioEngine)], screen: NSScreen) {
        window = MultiviewWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.title = "RadioPocket — Video Multiview"
        window.isReleasedWhenClosed = false; window.backgroundColor = .black; window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = wall
        for panel in panels {
            let tile = MultiviewTile(player: panel.engine.player)
            tile.name = panel.name
            tile.onClick = { [weak self] in self?.onTakeAudio?(panel.engine) }
            tiles.append((panel.engine, tile))
        }
        wall.tiles = tiles.map(\.tile)
        window.onEscape = { [weak self] in self?.exit() }
        FullScreenPresentation.enter()
        window.level = .statusBar
        window.setFrame(screen.frame, display: true)
        window.makeKeyAndOrderFront(nil)
    }

    func setAudible(_ engine: RadioEngine) { for entry in tiles { entry.tile.audible = entry.engine === engine } }
    func rename(_ names: [String]) { for (entry, name) in zip(tiles, names) { entry.tile.name = name } }

    func exit() {
        guard !closed else { return }
        closed = true
        window.orderOut(nil)
        FullScreenPresentation.leave()
        onExit?()
    }
}
#endif
