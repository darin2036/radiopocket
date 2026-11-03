import UIKit

/// The classic 275 × 116 equalizer window: eleven sliders, ON, AUTO (here: flat) and PRESETS, drawn from EQMAIN.BMP.
final class ClassicEqualizerView: UIView {
    let equalizer: Equalizer
    var skin: ClassicSkin? { didSet { setNeedsDisplay() } }
    var presetsRequested: (() -> Void)?
    private static let size = CGSize(width: 275, height: 116)
    private static let on = CGRect(x: 14, y: 18, width: 26, height: 12)
    private static let flat = CGRect(x: 40, y: 18, width: 32, height: 12)
    private static let presets = CGRect(x: 217, y: 18, width: 44, height: 12)
    private static func sliderX(_ index: Int) -> CGFloat { index == 0 ? 21 : CGFloat(78 + (index - 1) * 18) }
    private var pressed: String?
    private var slider: Int?

    init(equalizer: Equalizer) {
        self.equalizer = equalizer
        super.init(frame: .zero)
        backgroundColor = .black
        isOpaque = true
        contentMode = .redraw
        isMultipleTouchEnabled = false
    }
    required init?(coder: NSCoder) { fatalError() }

    private var layout: (scale: CGFloat, origin: CGPoint) {
        let scale = min(bounds.width / Self.size.width, bounds.height / Self.size.height)
        return (scale, CGPoint(x: (bounds.width - Self.size.width * scale) / 2, y: (bounds.height - Self.size.height * scale) / 2))
    }
    private func local(_ point: CGPoint) -> CGPoint {
        let (scale, origin) = layout
        return CGPoint(x: (point.x - origin.x) / scale, y: (point.y - origin.y) / scale)
    }
    private func value(_ index: Int) -> Float { index == 0 ? equalizer.settings.preamp : equalizer.settings.bands[index - 1] }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        context.interpolationQuality = .none
        let (scale, origin) = layout
        context.translateBy(x: origin.x, y: origin.y)
        context.scaleBy(x: scale, y: scale)
        context.setFillColor(UIColor(red: 0.19, green: 0.20, blue: 0.25, alpha: 1).cgColor)
        context.fill(CGRect(origin: .zero, size: Self.size))
        sprite(CGRect(x: 0, y: 0, width: 275, height: 116), at: CGRect(x: 0, y: 0, width: 275, height: 116))
        sprite(CGRect(x: 0, y: 134, width: 275, height: 14), at: CGRect(x: 0, y: 0, width: 275, height: 14))
        sprite(CGRect(x: 0, y: 294, width: 113, height: 19), at: CGRect(x: 86, y: 17, width: 113, height: 19))

        // The curve across the graph, as on the desktop.
        context.saveGState(); context.clip(to: CGRect(x: 86, y: 17, width: 113, height: 19))
        context.setStrokeColor((skin?.displayForeground ?? .green).cgColor); context.setLineWidth(0.7)
        for (i, gain) in equalizer.settings.bands.enumerated() {
            let point = CGPoint(x: 86 + CGFloat(i) * 12.4, y: 26.5 - CGFloat(gain) * 0.65)
            if i == 0 { context.move(to: point) } else { context.addLine(to: point) }
        }
        context.strokePath(); context.restoreGState()

        for index in 0...10 {
            let value = CGFloat(self.value(index)), x = Self.sliderX(index)
            let frame = Int(((value + 12) / 24 * 27).rounded())
            sprite(CGRect(x: 13 + (frame % 14) * 15, y: 164 + (frame / 14) * 65, width: 14, height: 63), at: CGRect(x: x, y: 38, width: 14, height: 63))
            sprite(CGRect(x: 0, y: slider == index ? 176 : 164, width: 11, height: 11), at: CGRect(x: x + 1, y: 38 + ((12 - value) / 24 * 51).rounded(), width: 11, height: 11))
        }
        let enabled = equalizer.settings.enabled, down = pressed == "on"
        sprite(CGRect(x: enabled ? (down ? 187 : 69) : (down ? 128 : 10), y: 119, width: 26, height: 12), at: Self.on)
        sprite(CGRect(x: 224, y: pressed == "presets" ? 176 : 164, width: 44, height: 12), at: Self.presets)
    }

    private func sprite(_ source: CGRect, at target: CGRect) { skin?.sprite("eqmain.bmp", source)?.draw(in: target) }

    // MARK: Touch

    private func sliderIndex(at p: CGPoint) -> Int? {
        guard p.y >= 34, p.y <= 104 else { return nil }
        return (0...10).min { abs(Self.sliderX($0) + 7 - p.x) < abs(Self.sliderX($1) + 7 - p.x) }.flatMap { abs(Self.sliderX($0) + 7 - p.x) <= 9 ? $0 : nil }
    }
    private func set(_ index: Int, _ value: Float) {
        var settings = equalizer.settings
        let clamped = min(12, max(-12, value))
        if index == 0 { settings.preamp = clamped } else { settings.bands[index - 1] = clamped }
        settings.preset = "Custom"
        equalizer.settings = settings
    }
    private func drag(_ index: Int, _ p: CGPoint) { set(index, Float(12 - (p.y - 38 - 5.5) / 51 * 24)) }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        let p = local(touch.location(in: self))
        if let index = sliderIndex(at: p) {
            slider = index
            if touch.tapCount == 2 { set(index, 0) } else { drag(index, p) }
        } else if Self.on.insetBy(dx: -2, dy: -4).contains(p) { pressed = "on" }
        else if Self.flat.insetBy(dx: -2, dy: -4).contains(p) { pressed = "flat" }
        else if Self.presets.insetBy(dx: -2, dy: -4).contains(p) { pressed = "presets" }
        setNeedsDisplay()
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let slider, let touch = touches.first else { return }
        drag(slider, local(touch.location(in: self)))
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        defer { pressed = nil; slider = nil; setNeedsDisplay() }
        guard let id = pressed else { return }
        switch id {
        case "on": equalizer.settings.enabled.toggle()
        case "flat": equalizer.select(EQPreset.classic.first { $0.name == "Flat" }!)
        default: presetsRequested?()
        }
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { pressed = nil; slider = nil; setNeedsDisplay() }
}
