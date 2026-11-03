import UIKit

/// The classic playlist window frame, drawn from PLEDIT.BMP, around a station list. The list sits in the window's content area.
final class ClassicPlaylistView: UIView {
    static let width: CGFloat = 275
    /// Content area in skin units: inside the 12-pixel left edge, 20-pixel right edge, 20-pixel title bar and 38-pixel footer.
    private static let insets = UIEdgeInsets(top: 20, left: 12, bottom: 38, right: 20)
    var skin: ClassicSkin? { didSet { setNeedsDisplay() } }
    /// Called with `add`, `remove`, `select`, `misc` or `options` when a footer button is tapped.
    var action: ((String) -> Void)?
    private var pressed: String?
    private let buttons: [(id: String, x: CGFloat, width: CGFloat)] = [("add", 12, 25), ("remove", 41, 25), ("select", 70, 25), ("misc", 99, 25), ("options", 230, 25)]

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        isOpaque = true
        contentMode = .redraw
    }
    required init?(coder: NSCoder) { fatalError() }

    var scale: CGFloat { bounds.width / Self.width }
    /// Where the station list goes, in this view's points.
    var contentFrame: CGRect {
        let s = scale, i = Self.insets
        return CGRect(x: i.left * s, y: i.top * s, width: bounds.width - (i.left + i.right) * s, height: max(0, bounds.height - (i.top + i.bottom) * s))
    }
    private var heightInUnits: CGFloat { bounds.height / scale }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        context.interpolationQuality = .none
        let s = scale, h = heightInUnits
        context.scaleBy(x: s, y: s)
        let palette = skin?.palette ?? .native
        context.setFillColor(palette.item.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: Self.width, height: h))
        func sprite(_ source: CGRect, _ target: CGRect, clip: CGRect? = nil) {
            context.saveGState()
            if let clip { context.clip(to: clip) }
            skin?.sprite("pledit.bmp", source)?.draw(in: target)
            context.restoreGState()
        }
        // Title bar: corners and centred title, with the filler tile repeated between.
        let top = CGRect(x: 0, y: 0, width: Self.width, height: 20)
        let titleX = ((Self.width - 100) / 2).rounded(.down)
        var x: CGFloat = 25
        while x < Self.width - 25 { sprite(CGRect(x: 127, y: 0, width: 25, height: 20), CGRect(x: x, y: 0, width: 25, height: 20), clip: top.intersection(CGRect(x: 25, y: 0, width: Self.width - 50, height: 20))); x += 25 }
        sprite(CGRect(x: 0, y: 0, width: 25, height: 20), CGRect(x: 0, y: 0, width: 25, height: 20))
        sprite(CGRect(x: 26, y: 0, width: 100, height: 20), CGRect(x: titleX, y: 0, width: 100, height: 20))
        sprite(CGRect(x: 153, y: 0, width: 25, height: 20), CGRect(x: Self.width - 25, y: 0, width: 25, height: 20))
        // Side edges.
        var y: CGFloat = 20
        while y < h - 38 {
            let tile = min(29, h - 38 - y)
            sprite(CGRect(x: 0, y: 42, width: 12, height: tile), CGRect(x: 0, y: y, width: 12, height: tile))
            sprite(CGRect(x: 31, y: 42, width: 20, height: tile), CGRect(x: Self.width - 20, y: y, width: 20, height: tile))
            y += 29
        }
        // Footer: ADD / REM / SEL / MISC and LIST OPTS are part of its artwork.
        sprite(CGRect(x: 0, y: 72, width: 125, height: 38), CGRect(x: 0, y: h - 38, width: 125, height: 38))
        sprite(CGRect(x: 126, y: 72, width: 150, height: 38), CGRect(x: 125, y: h - 38, width: 150, height: 38))
    }

    private func button(at point: CGPoint) -> String? {
        let p = CGPoint(x: point.x / scale, y: point.y / scale), footer = heightInUnits - 30
        guard p.y >= footer - 4, p.y <= footer + 22 else { return nil }
        return buttons.first { p.x >= $0.x - 2 && p.x <= $0.x + $0.width + 2 }?.id
    }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) { pressed = touches.first.flatMap { button(at: $0.location(in: self)) } }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        defer { pressed = nil }
        guard let id = pressed, let touch = touches.first, button(at: touch.location(in: self)) == id else { return }
        action?(id)
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { pressed = nil }
}
