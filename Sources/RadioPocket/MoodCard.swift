import AppKit

/// Native vector illustrations stay crisp at every window size, with no artwork downloads.
final class MoodCard: NSButton {
    var choose: (() -> Void)?
    private let name: String
    private let count: Int
    private let unit: String
    private let caption: String?
    private var stationCount: String { "\(count) " + (count == 1 ? unit : unit + "s") }
    private let symbol: String
    private let tint: NSColor
    var compact = false { didSet { needsDisplay = true } }
    init(title: String, count: Int, unit: String = "station", artwork: String? = nil, caption: String? = nil) {
        name = title; self.count = count; self.unit = unit; self.caption = caption
        let lower = artwork ?? title.lowercased()
        if lower.contains("rain") { symbol = "cloud.rain.fill"; tint = NSColor(calibratedRed: 0.20, green: 0.39, blue: 0.55, alpha: 1) }
        else if lower.contains("snow") { symbol = "cloud.snow.fill"; tint = NSColor(calibratedRed: 0.29, green: 0.47, blue: 0.61, alpha: 1) }
        else if lower.contains("cloud") { symbol = "cloud.fill"; tint = NSColor(calibratedRed: 0.35, green: 0.43, blue: 0.57, alpha: 1) }
        else if lower.contains("morning") || lower == "sunrise" { symbol = "sunrise.fill"; tint = NSColor(calibratedRed: 0.72, green: 0.35, blue: 0.18, alpha: 1) }
        else if lower.contains("afternoon") || lower.contains("wandering") || lower == "sun" { symbol = "sun.max.fill"; tint = NSColor(calibratedRed: 0.72, green: 0.48, blue: 0.10, alpha: 1) }
        else if lower.contains("focus") { symbol = "headphones"; tint = NSColor(calibratedRed: 0.18, green: 0.47, blue: 0.43, alpha: 1) }
        else if lower.contains("energy") || lower.contains("hours") || lower == "party" { symbol = "sparkles"; tint = NSColor(calibratedRed: 0.64, green: 0.25, blue: 0.38, alpha: 1) }
        else if lower.contains("dinner") { symbol = "wineglass.fill"; tint = NSColor(calibratedRed: 0.48, green: 0.30, blue: 0.53, alpha: 1) }
        else { symbol = "moon.stars.fill"; tint = NSColor(calibratedRed: 0.25, green: 0.29, blue: 0.57, alpha: 1) }
        super.init(frame: .zero)
        self.title = title; isBordered = false; target = self; action = #selector(openMood)
        setAccessibilityLabel(title + ", " + stationCount + ". Open mood.")
        toolTip = "Explore " + title.lowercased()
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func openMood() { choose?() }
    override var isFlipped: Bool { true }
    private func drawBackdrop() {
        // Stable paper-cut variations; no animation or downloaded artwork.
        let variant = name.utf8.reduce(0) { ($0 + Int($1)) % 5 }
        NSColor.white.withAlphaComponent(0.10).setStroke()
        NSColor.white.withAlphaComponent(0.08).setFill()
        switch variant {
        case 0: // Flowing radio waves
            for offset in stride(from: CGFloat(-30), through: 180, by: 25) {
                let wave = NSBezierPath()
                wave.move(to: NSPoint(x: bounds.width * 0.35, y: offset))
                wave.curve(to: NSPoint(x: bounds.width + 20, y: offset + 35), controlPoint1: NSPoint(x: bounds.width * 0.65, y: offset - 65), controlPoint2: NSPoint(x: bounds.width * 0.8, y: offset + 85))
                wave.lineWidth = 9; wave.stroke()
            }
        case 1: // Diagonal paper ribbons
            for offset in stride(from: CGFloat(0), through: bounds.width + 160, by: 64) {
                let ribbon = NSBezierPath()
                ribbon.move(to: NSPoint(x: offset, y: 0)); ribbon.line(to: NSPoint(x: offset + 27, y: 0))
                ribbon.line(to: NSPoint(x: offset - 63, y: bounds.height)); ribbon.line(to: NSPoint(x: offset - 90, y: bounds.height)); ribbon.close(); ribbon.fill()
            }
        case 2: // Concentric record grooves
            for radius in stride(from: CGFloat(30), through: 230, by: 23) {
                let ring = NSBezierPath(ovalIn: NSRect(x: bounds.width - 30 - radius, y: -radius, width: radius * 2, height: radius * 2))
                ring.lineWidth = 7; ring.stroke()
            }
        case 3: // Scattered confetti
            for index in 0..<18 {
                let x = bounds.width * 0.40 + CGFloat((index * 47) % 170)
                let y = CGFloat((index * 37) % 145)
                let dot = NSBezierPath(roundedRect: NSRect(x: x, y: y, width: index % 3 == 0 ? 18 : 7, height: 7), xRadius: 3, yRadius: 3)
                dot.fill()
            }
        default: // Layered rolling hills
            for index in 0..<3 {
                let y = CGFloat(45 + index * 40)
                let hill = NSBezierPath()
                hill.move(to: NSPoint(x: 0, y: y + 40))
                hill.curve(to: NSPoint(x: bounds.width, y: y), controlPoint1: NSPoint(x: bounds.width * 0.35, y: y - 70), controlPoint2: NSPoint(x: bounds.width * 0.7, y: y + 90))
                hill.line(to: NSPoint(x: bounds.width, y: bounds.height)); hill.line(to: NSPoint(x: 0, y: bounds.height)); hill.close(); hill.fill()
            }
        }
    }
    override func draw(_ dirtyRect: NSRect) {
        let card = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 14, yRadius: 14)
        NSGraphicsContext.saveGraphicsState(); card.addClip()
        NSGradient(starting: tint, ending: tint.blended(withFraction: 0.60, of: .black)!)?.draw(in: bounds, angle: 90)
        drawBackdrop()
        if let icon = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 40, weight: .regular)) {
            let rect = compact ? NSRect(x: bounds.width - 46, y: 12, width: 32, height: 30) : NSRect(x: 16, y: 12, width: 52, height: 44)
            let colored = NSImage(size: icon.size, flipped: false) { area in
                icon.draw(in: area); NSColor(calibratedRed: 1, green: 0.90, blue: 0.64, alpha: 1).setFill(); area.fill(using: .sourceAtop); return true
            }
            let scale = min(rect.width / max(1, colored.size.width), rect.height / max(1, colored.size.height))
            let fitted = NSRect(x: rect.midX - colored.size.width * scale / 2, y: rect.midY - colored.size.height * scale / 2, width: colored.size.width * scale, height: colored.size.height * scale)
            colored.draw(in: fitted, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byWordWrapping
        let titleRect = compact ? NSRect(x: 12, y: 16, width: bounds.width - 64, height: 60) : NSRect(x: 16, y: 65, width: bounds.width - 32, height: 48)
        let titleSize: CGFloat = compact ? 15 : bounds.width < 205 ? 16 : 18
        (name as NSString).draw(in: titleRect, withAttributes: [.font: NSFont.systemFont(ofSize: titleSize, weight: .semibold), .foregroundColor: NSColor.white, .paragraphStyle: paragraph])
        ((stationCount + "  ·  Explore →") as NSString).draw(in: NSRect(x: compact ? 12 : 16, y: bounds.height - 26, width: bounds.width - (compact ? 24 : 32), height: 18), withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.white.withAlphaComponent(0.85)])
        if isHighlighted { NSColor.white.withAlphaComponent(0.12).setFill(); bounds.fill() }
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// One shared column width, including incomplete final rows. Reflows without recreating buttons.
final class MoodCardGrid: NSView {
    private let cards: [MoodCard]
    private var gridHeight: NSLayoutConstraint!
    init(cards: [MoodCard]) {
        self.cards = cards
        super.init(frame: .zero)
        for card in cards { addSubview(card) }
        gridHeight = heightAnchor.constraint(equalToConstant: 148)
        gridHeight.isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func layout() {
        super.layout()
        let width = bounds.width
        guard width > 0 else { return }
        let tight = width < 470 || (enclosingScrollView.map { $0.contentView.bounds.height < 430 } ?? false)
        let gap: CGFloat = tight ? 8 : 12
        let minimum: CGFloat = tight ? 170 : 190
        let columns = max(1, min(3, Int((width + gap) / (minimum + gap))))
        let cardWidth = (width - CGFloat(columns - 1) * gap) / CGFloat(columns)
        let cardHeight: CGFloat = tight ? 108 : 148
        let rows = (cards.count + columns - 1) / columns
        let height = CGFloat(rows) * cardHeight + CGFloat(max(0, rows - 1)) * gap
        if gridHeight.constant != height { gridHeight.constant = height }
        for (index, card) in cards.enumerated() {
            card.compact = tight
            card.frame = NSRect(x: CGFloat(index % columns) * (cardWidth + gap), y: CGFloat(index / columns) * (cardHeight + gap), width: cardWidth, height: cardHeight)
        }
    }
}
