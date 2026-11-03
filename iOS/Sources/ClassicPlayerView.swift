import UIKit

/// The classic 275 × 116 Winamp main window, drawn from the skin's sprite sheets and scaled to fit, with touch in place of the mouse.
final class ClassicPlayerView: UIView {
    static let size = CGSize(width: 275, height: 116)
    private static let volumeSlot = CGRect(x: 107, y: 57, width: 68, height: 16)
    private static let balanceSlot = CGRect(x: 177, y: 57, width: 38, height: 16)
    private static let transport = (0..<5).map { CGRect(x: 16 + $0 * 23, y: 88, width: $0 == 4 ? 22 : 23, height: 18) }
    private static let buttons: [(id: String, rect: CGRect)] = [
        ("previous", transport[0]), ("play", transport[1]), ("pause", transport[2]), ("stop", transport[3]), ("next", transport[4]),
        ("open", CGRect(x: 136, y: 89, width: 22, height: 16)),
        ("equalizer", CGRect(x: 219, y: 58, width: 23, height: 12)),
        ("library", CGRect(x: 242, y: 58, width: 23, height: 12)),
    ]

    let engine: RadioEngine
    var skin: ClassicSkin? { didSet { setNeedsDisplay() } }
    var action: ((String) -> Void)?
    var volumeChanged: ((Float) -> Void)?
    var balanceChanged: ((Float) -> Void)?
    private var pressed: String?
    private var armed: String?
    private enum Drag { case volume, balance }
    private var dragging: Drag?

    init(engine: RadioEngine) {
        self.engine = engine
        super.init(frame: .zero)
        backgroundColor = .black
        isOpaque = true
        contentMode = .redraw
        isMultipleTouchEnabled = false
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Largest scale at which the window fits the view, centred.
    private var layout: (scale: CGFloat, origin: CGPoint) {
        let scale = min(bounds.width / Self.size.width, bounds.height / Self.size.height)
        return (scale, CGPoint(x: (bounds.width - Self.size.width * scale) / 2, y: (bounds.height - Self.size.height * scale) / 2))
    }
    private func local(_ point: CGPoint) -> CGPoint {
        let (scale, origin) = layout
        return CGPoint(x: (point.x - origin.x) / scale, y: (point.y - origin.y) / scale)
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        context.interpolationQuality = .none
        let (scale, origin) = layout
        context.translateBy(x: origin.x, y: origin.y)
        context.scaleBy(x: scale, y: scale)
        context.setFillColor(UIColor(red: 0.19, green: 0.20, blue: 0.25, alpha: 1).cgColor)
        context.fill(CGRect(origin: .zero, size: Self.size))
        guard let skin else { return }
        sprite("main.bmp", CGRect(x: 0, y: 0, width: 275, height: 116), at: CGRect(x: 0, y: 0, width: 275, height: 116))
        sprite("titlebar.bmp", CGRect(x: 27, y: 0, width: 275, height: 14), at: CGRect(x: 0, y: 0, width: 275, height: 14))

        let minutes = min(engine.elapsed / 60, 99)
        let digits = String(format: "%02d%02d", minutes, engine.elapsed % 60)
        let numbers = skin.sprite("nums_ex.bmp", CGRect(x: 0, y: 0, width: 9, height: 13)) != nil ? "nums_ex.bmp" : "numbers.bmp"
        for (i, digit) in digits.enumerated() {
            sprite(numbers, CGRect(x: Int(String(digit))! * 9, y: 0, width: 9, height: 13), at: CGRect(x: [48, 60, 78, 90][i], y: 26, width: 9, height: 13))
        }
        let indicator: CGFloat = engine.status == .playing ? 0 : engine.status == .paused ? 9 : 18
        sprite("playpaus.bmp", CGRect(x: indicator, y: 0, width: 9, height: 9), at: CGRect(x: 24, y: 28, width: 9, height: 9))

        bitmapText([.connecting, .failed].contains(engine.status) ? engine.detail : engine.title, in: CGRect(x: 111, y: 27, width: 154, height: 6))
        let info = engine.status == .playing || engine.status == .paused ? engine.streamInfo : nil
        bitmapText(info?.kbps.map { String(min($0, 999)) } ?? "---", in: CGRect(x: 111, y: 43, width: 15, height: 6))
        bitmapText(info.map { String(Int(($0.sampleRate / 1000).rounded())) } ?? "--", in: CGRect(x: 156, y: 43, width: 10, height: 6))
        // Both indicators stay unlit until the stream has reported its channel count.
        let unknown = info == nil, stereo = (info?.channels ?? 0) > 1
        sprite("monoster.bmp", CGRect(x: 29, y: unknown || stereo ? 12 : 0, width: 27, height: 12), at: CGRect(x: 212, y: 41, width: 27, height: 12))
        sprite("monoster.bmp", CGRect(x: 0, y: unknown || !stereo ? 12 : 0, width: 29, height: 12), at: CGRect(x: 239, y: 41, width: 29, height: 12))

        let volume = CGFloat(engine.player.volume)
        sprite("volume.bmp", CGRect(x: 0, y: CGFloat(Int(volume * 27) * 15), width: 68, height: 13), at: CGRect(x: 107, y: 57, width: 68, height: 13))
        sprite("volume.bmp", CGRect(x: 15, y: 422, width: 14, height: 11), at: CGRect(x: 107 + (51 * volume).rounded(), y: 58, width: 14, height: 11))
        let balance = CGFloat(engine.balance)
        sprite("balance.bmp", CGRect(x: 9, y: CGFloat(Int((abs(balance) * 27).rounded()) * 15), width: 38, height: 13), at: CGRect(x: 177, y: 57, width: 38, height: 13))
        sprite("balance.bmp", CGRect(x: 15, y: 422, width: 14, height: 11), at: CGRect(x: 177 + ((balance + 1) * 12).rounded(), y: 58, width: 14, height: 11))

        // Pressed states come from the same sheets as the idle ones.
        for (i, rect) in Self.transport.enumerated() {
            let down = pressed == ["previous", "play", "pause", "stop", "next"][i]
            sprite("cbuttons.bmp", CGRect(x: CGFloat(i * 23), y: down ? 18 : 0, width: rect.width, height: 18), at: rect)
        }
        sprite("cbuttons.bmp", CGRect(x: 114, y: pressed == "open" ? 16 : 0, width: 22, height: 16), at: Self.buttons[5].rect)
        sprite("shufrep.bmp", CGRect(x: pressed == "equalizer" ? 46 : 0, y: 61, width: 23, height: 12), at: Self.buttons[6].rect)
        sprite("shufrep.bmp", CGRect(x: 23 + (pressed == "library" ? 46 : 0), y: 61, width: 23, height: 12), at: Self.buttons[7].rect)
    }

    private func sprite(_ sheet: String, _ source: CGRect, at target: CGRect) {
        skin?.sprite(sheet, source)?.draw(in: target)
    }

    private func bitmapText(_ value: String, in rect: CGRect) {
        guard let skin, let context = UIGraphicsGetCurrentContext() else { return }
        context.saveGState(); context.clip(to: rect)
        let capacity = Int(rect.width / 5)
        var chars = Array(value.prefix(capacity))
        if value.count > capacity, capacity > 0 { chars[capacity - 1] = "…" }
        for (i, char) in chars.enumerated() {
            skin.glyph(char)?.draw(in: CGRect(x: rect.minX + CGFloat(i * 5), y: rect.minY, width: 5, height: 6))
        }
        context.restoreGState()
    }

    // MARK: Touch

    private func button(at point: CGPoint) -> String? {
        // Controls are small in skin units; grow each hit area a little, which the scale makes generous on a phone.
        Self.buttons.first { $0.rect.insetBy(dx: -2, dy: -3).contains(point) }?.id
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        let p = local(touch.location(in: self))
        if Self.volumeSlot.contains(p) { dragging = .volume; adjustVolume(p) }
        else if Self.balanceSlot.contains(p) { dragging = .balance; adjustBalance(p) }
        else { armed = button(at: p); pressed = armed; setNeedsDisplay() }
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        let p = local(touch.location(in: self))
        switch dragging {
        case .volume: adjustVolume(p)
        case .balance: adjustBalance(p)
        case nil:
            let next = button(at: p) == armed ? armed : nil
            if next != pressed { pressed = next; setNeedsDisplay() }
        }
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        defer { pressed = nil; armed = nil; dragging = nil; setNeedsDisplay() }
        guard dragging == nil, let id = pressed else { return }
        action?(id)
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { pressed = nil; armed = nil; dragging = nil; setNeedsDisplay() }

    private func adjustVolume(_ p: CGPoint) { volumeChanged?(Float(min(1, max(0, (p.x - 114) / 51)))) }
    private func adjustBalance(_ p: CGPoint) { balanceChanged?(StereoBalance.snapped(Float((p.x - 184) / 12 - 1))) }
}
