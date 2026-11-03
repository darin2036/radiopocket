import AppKit

/// Small controls shared by every shaded (title-bar-only) panel: a mini transport and a scrolling now-playing display.
/// Both are drawn as flat "LCD" insets so they read the same on any skin and any bar height.
extension ClassicUI {
    static let playbackChanged = Notification.Name("RadioPocketPlaybackChanged")
    /// Whether playback is running or starting, for the play/pause glyph.
    static var isPlaying: () -> Bool = { false }
    /// Runs a player action ("toggle", "previous", "next").
    static var transport: (String) -> Void = { _ in }

    /// A recessed display well behind shaded-bar content.
    static func inset(_ rect: NSRect, background: NSColor = black) {
        background.setFill(); rect.fill()
        NSColor(white: 0, alpha: 0.5).setStroke()
        NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5)).stroke()
    }
}

enum MiniGlyph {
    case previous, play, pause, next
    /// Draws into an 8×8 cell centred in `rect`.
    func draw(in rect: NSRect, color: NSColor) {
        color.setFill()
        let cell = NSRect(x: (rect.midX - 4).rounded(), y: (rect.midY - 4).rounded(), width: 8, height: 8)
        func triangle(from tip: CGFloat, to base: CGFloat) {
            let path = NSBezierPath()
            path.move(to: NSPoint(x: base, y: cell.minY)); path.line(to: NSPoint(x: base, y: cell.maxY)); path.line(to: NSPoint(x: tip, y: cell.midY)); path.close(); path.fill()
        }
        switch self {
        case .play: triangle(from: cell.maxX - 1, to: cell.minX + 1)
        case .pause:
            NSRect(x: cell.minX + 1, y: cell.minY, width: 2, height: 8).fill()
            NSRect(x: cell.minX + 5, y: cell.minY, width: 2, height: 8).fill()
        case .previous:
            NSRect(x: cell.minX, y: cell.minY, width: 2, height: 8).fill()
            triangle(from: cell.minX + 2, to: cell.maxX)
        case .next:
            NSRect(x: cell.maxX - 2, y: cell.minY, width: 2, height: 8).fill()
            triangle(from: cell.maxX - 2, to: cell.minX)
        }
    }
}

/// Previous, play/pause and next in one inset. Sized to the bar it sits in.
final class MiniTransport: NSView {
    static let width: CGFloat = 38
    private static let ids = ["previous", "toggle", "next"]
    var colors: () -> (foreground: NSColor, background: NSColor) = { (ClassicUI.green, ClassicUI.black) }
    private var pressed: Int?
    private var inside = false
    private var observer: NSObjectProtocol?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityRole(.group); setAccessibilityLabel("Playback controls")
    }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let observer { NotificationCenter.default.removeObserver(observer); self.observer = nil }
        guard window != nil else { return }
        observer = NotificationCenter.default.addObserver(forName: ClassicUI.playbackChanged, object: nil, queue: .main) { [weak self] _ in
            if self?.isHiddenOrHasHiddenAncestor == false { self?.needsDisplay = true }
        }
    }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    private func cell(_ index: Int) -> NSRect { NSRect(x: 1 + CGFloat(index) * 12, y: 0, width: 12, height: bounds.height) }
    private func index(at point: NSPoint) -> Int? { (0..<3).first { cell($0).contains(point) } }
    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.current?.imageInterpolation = .none
        let (foreground, background) = colors()
        ClassicUI.inset(bounds, background: background)
        let glyphs: [MiniGlyph] = [.previous, ClassicUI.isPlaying() ? .pause : .play, .next]
        for (i, glyph) in glyphs.enumerated() {
            if pressed == i, inside { foreground.withAlphaComponent(0.28).setFill(); cell(i).insetBy(dx: 0, dy: 1).fill() }
            glyph.draw(in: cell(i), color: foreground)
        }
    }
    override func mouseDown(with event: NSEvent) {
        pressed = index(at: convert(event.locationInWindow, from: nil)); inside = pressed != nil; needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        let now = index(at: convert(event.locationInWindow, from: nil)) == pressed
        if now != inside { inside = now; needsDisplay = true }
    }
    override func mouseUp(with event: NSEvent) {
        defer { pressed = nil; needsDisplay = true }
        if let pressed, inside { ClassicUI.transport(Self.ids[pressed]) }
    }
}

/// One line of text in an inset that scrolls when it doesn't fit. Without an `onClick`, clicks fall through to the bar
/// behind it, so the display still drags the window and double-clicks to restore it.
final class MarqueeLabel: NSView {
    var text: () -> String
    var font: NSFont
    var onClick: (() -> Void)?
    var showsChevron = false
    var colors: () -> (foreground: NSColor, background: NSColor) = { (ClassicUI.green, ClassicUI.black) }
    private var current = ""
    private var start = Date()
    private var overflows = false
    private var timer: Timer?
    override var isFlipped: Bool { true }
    init(frame: NSRect, font: NSFont, text: @escaping () -> String) {
        self.font = font; self.text = text
        super.init(frame: frame)
        setAccessibilityRole(.staticText)
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { timer?.invalidate() }

    // The timer exists only while the display is on screen; text that fits needs no animation, only change detection.
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); updateTimer() }
    override func viewDidHide() { super.viewDidHide(); updateTimer() }
    override func viewDidUnhide() { super.viewDidUnhide(); updateTimer() }
    private func updateTimer() {
        timer?.invalidate(); timer = nil
        guard window != nil, !isHiddenOrHasHiddenAncestor else { return }
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.tick() }
        timer.tolerance = 0.03
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
    private func tick() {
        guard let window, window.isVisible, window.occlusionState.contains(.visible) else { return }
        if overflows || text() != current { needsDisplay = true }
    }
    private var textArea: NSRect { NSRect(x: 3, y: 0, width: bounds.width - (showsChevron ? 16 : 6), height: bounds.height) }

    override func draw(_ dirtyRect: NSRect) {
        let (foreground, background) = colors()
        ClassicUI.inset(bounds, background: background)
        let value = text()
        if value != current { current = value; start = Date() }
        setAccessibilityValue(value)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: foreground]
        let size = (value as NSString).size(withAttributes: attributes)
        let area = textArea, y = (bounds.midY - size.height / 2).rounded(.down)
        overflows = size.width > area.width
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: area).addClip()
        if overflows {
            let gap: CGFloat = 40, cycle = size.width + gap
            // Hold the start of the text for a moment, then scroll at a steady pace.
            let travelled = CGFloat(max(0, Date().timeIntervalSince(start) - 1.5)) * ClassicUI.scrollSpeed
            var x = area.minX - travelled.truncatingRemainder(dividingBy: cycle)
            while x < area.maxX { (value as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: attributes); x += cycle }
        } else {
            (value as NSString).draw(at: NSPoint(x: area.minX, y: y), withAttributes: attributes)
        }
        NSGraphicsContext.restoreGraphicsState()
        if showsChevron {
            foreground.setFill()
            let tip = NSPoint(x: bounds.maxX - 8, y: bounds.midY + 1.5)
            let path = NSBezierPath()
            path.move(to: NSPoint(x: tip.x - 3, y: tip.y - 3)); path.line(to: NSPoint(x: tip.x + 3, y: tip.y - 3)); path.line(to: tip); path.close(); path.fill()
        }
    }
    override func mouseDown(with event: NSEvent) {
        if let onClick { onClick() } else { superview?.mouseDown(with: event) }
    }
}

/// A vertical-only list container: its table's last visible column always stretches or shrinks to the clip width,
/// so a fixed column width can never produce a sideways scroll, and horizontal wheel input is ignored.
final class FittedScrollView: NSScrollView {
    override init(frame: NSRect) { super.init(frame: frame); configure() }
    required init?(coder: NSCoder) { super.init(coder: coder); configure() }
    private func configure() {
        hasHorizontalScroller = false; horizontalScrollElasticity = .none
    }
    override func tile() {
        super.tile()
        fitLastColumn()
    }
    override func scrollWheel(with event: NSEvent) {
        if abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) { return }
        super.scrollWheel(with: event)
    }
    private func fitLastColumn() {
        guard let table = documentView as? NSTableView else { return }
        let visible = table.tableColumns.filter { !$0.isHidden }
        guard let last = visible.last else { return }
        let others = visible.dropLast().reduce(CGFloat(0)) { $0 + $1.width }
        let spacing = table.intercellSpacing.width * CGFloat(visible.count - 1)
        let width = max(last.minWidth, contentSize.width - others - spacing - table.intercellSpacing.width)
        if abs(last.width - width) > 0.5 { last.width = width }
        if table.frame.width != contentSize.width, table.frame.width > contentSize.width { table.setFrameSize(NSSize(width: contentSize.width, height: table.frame.height)) }
        contentView.scroll(to: NSPoint(x: 0, y: contentView.bounds.origin.y))
    }
}
