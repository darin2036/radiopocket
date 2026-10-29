import AppKit

/// Shared compact control metrics for the player’s secondary windows.
enum ClassicUI {
    static let font = NSFont(name: "Tahoma", size: 11) ?? .systemFont(ofSize: 11)
    static let small = font
    static let panel = NSColor(calibratedRed: 0.16, green: 0.16, blue: 0.21, alpha: 1)
    static let black = NSColor(white: 0.025, alpha: 1)
    static let green = NSColor(calibratedRed: 0.25, green: 1, blue: 0.05, alpha: 1)
    static let text = NSColor(white: 0.84, alpha: 1)
    static let dim = NSColor(white: 0.60, alpha: 1)
    static let selection = NSColor(calibratedRed: 0.15, green: 0.19, blue: 0.35, alpha: 1)
    static var skin: ClassicSkin? { didSet {
        for window in NSApp.windows { window.contentView?.needsDisplay = true }
    } }
    static func bevel(_ rect: NSRect, down: Bool = false) {
        NSColor(white: down ? 0.46 : 0.68, alpha: 1).setFill(); rect.fill()
        (down ? NSColor(white: 0.14, alpha: 1) : NSColor(white: 0.90, alpha: 1)).setFill()
        NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: 1).fill()
        NSRect(x: rect.minX, y: rect.minY, width: 1, height: rect.height).fill()
        (down ? NSColor(white: 0.90, alpha: 1) : NSColor(white: 0.14, alpha: 1)).setFill()
        NSRect(x: rect.minX, y: rect.maxY - 1, width: rect.width, height: 1).fill()
        NSRect(x: rect.maxX - 1, y: rect.minY, width: 1, height: rect.height).fill()
    }
    static func caption(_ title: String, rect: NSRect, color: NSColor = .black, font: NSFont = font, alignment: NSTextAlignment = .center) {
        let style = NSMutableParagraphStyle(); style.alignment = alignment; style.lineBreakMode = .byTruncatingTail
        let height = ceil(font.ascender - font.descender + font.leading)
        (title as NSString).draw(in: NSRect(x: rect.minX + 3, y: floor(rect.midY - height / 2), width: rect.width - 6, height: height + 1), withAttributes: [.font: font, .foregroundColor: color, .paragraphStyle: style])
    }
    static func field(_ field: NSTextField) {
        field.font = font; field.textColor = text; field.backgroundColor = black
        field.isBezeled = false; field.isBordered = true; field.bezelStyle = .squareBezel; field.drawsBackground = true; field.focusRingType = .none
    }
}

class ClassicButton: NSButton {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        ClassicUI.bevel(bounds, down: isHighlighted)
        ClassicUI.caption(title, rect: bounds.offsetBy(dx: isHighlighted ? 1 : 0, dy: isHighlighted ? 1 : 0), color: NSColor(white: isEnabled ? 0.07 : 0.38, alpha: 1))
        if window?.firstResponder === self { NSColor.darkGray.setStroke(); NSBezierPath(rect: bounds.insetBy(dx: 3, dy: 3)).stroke() }
    }
}
final class ClassicPopup: NSPopUpButton {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        ClassicUI.bevel(bounds, down: isHighlighted)
        ClassicUI.caption(title, rect: NSRect(x: 2, y: 0, width: bounds.width - 17, height: bounds.height), color: isEnabled ? .black : .darkGray, alignment: .left)
        ClassicUI.caption("▾", rect: NSRect(x: bounds.width - 18, y: 0, width: 17, height: bounds.height))
    }
}
final class ClassicCombo: NSComboBox {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        ClassicUI.black.setFill(); bounds.fill()
        NSColor.gray.setStroke(); NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5)).stroke()
        ClassicUI.caption(stringValue, rect: NSRect(x: 1, y: 0, width: bounds.width - 19, height: bounds.height), color: isEnabled ? ClassicUI.text : ClassicUI.dim, alignment: .left)
        let arrow = NSRect(x: bounds.width - 18, y: 0, width: 18, height: bounds.height)
        ClassicUI.bevel(arrow); ClassicUI.caption("▾", rect: arrow)
    }
}

class ClassicChrome: NSView {
    var title = "MEDIA LIBRARY" { didSet { needsDisplay = true } }
    private var resizeStart: (NSRect, NSPoint)?
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        ClassicUI.panel.setFill(); bounds.fill()
        NSColor.gray.setStroke(); NSBezierPath(rect: bounds.insetBy(dx: 1, dy: 1)).stroke()
        let h = bounds.height, w = bounds.width
        func sprite(_ source: NSRect, _ target: NSRect) -> Bool {
            guard let image = ClassicUI.skin?.sprite("gen.bmp", source) else { return false }
            image.draw(in: target, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.none.rawValue]); return true
        }
        if sprite(NSRect(x: 0, y: 0, width: 25, height: 20), NSRect(x: 0, y: 0, width: 25, height: 20)) {
            for x in stride(from: CGFloat(25), to: w - 25, by: 25) {
                _ = sprite(NSRect(x: 104, y: 0, width: min(25, w - 25 - x), height: 20), NSRect(x: x, y: 0, width: min(25, w - 25 - x), height: 20))
            }
            _ = sprite(NSRect(x: 130, y: 0, width: 25, height: 20), NSRect(x: w - 25, y: 0, width: 25, height: 20))
            for y in stride(from: CGFloat(20), to: h - 14, by: 29) {
                let height = min(29, h - 14 - y)
                _ = sprite(NSRect(x: 127, y: 42, width: 11, height: height), NSRect(x: 0, y: y, width: 11, height: height))
                _ = sprite(NSRect(x: 139, y: 42, width: 8, height: height), NSRect(x: w - 8, y: y, width: 8, height: height))
            }
            for x in stride(from: CGFloat(0), to: w, by: 25) { _ = sprite(NSRect(x: 127, y: 72, width: min(25, w-x), height: 14), NSRect(x: x, y: h-14, width: min(25, w-x), height: 14)) }
        } else {
            for y in [4, 7, 10, 13] { NSColor(white: 0.55, alpha: 1).setFill(); NSRect(x: 8, y: CGFloat(y), width: w - 16, height: 1).fill() }
        }
        let tw = min(w - 90, CGFloat(title.count * 7 + 20))
        let label = NSRect(x: (w - tw)/2, y: 2, width: tw, height: 16)
        ClassicUI.panel.setFill(); label.fill()
        ClassicUI.caption(title, rect: label, color: ClassicUI.text, font: .monospacedSystemFont(ofSize: 10, weight: .bold))
        ClassicUI.dim.setStroke()
        if window?.styleMask.contains(.resizable) == true { for i in 0..<3 { let p = NSBezierPath(); p.move(to: NSPoint(x: w-5-CGFloat(i*3), y: h-4)); p.line(to: NSPoint(x:w-4,y:h-5-CGFloat(i*3))); p.stroke() } }
    }
    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if p.x > bounds.maxX-18 && p.y > bounds.maxY-18, let window, window.styleMask.contains(.resizable) { resizeStart = (window.frame, NSEvent.mouseLocation) }
        else if p.y < 20 { window?.performDrag(with: event) }
    }
    override func mouseDragged(with event: NSEvent) {
        guard let (start, point) = resizeStart, let window else { return }
        let delta = NSEvent.mouseLocation
        let width = max(window.minSize.width, start.width+delta.x-point.x)
        let height = max(window.minSize.height, start.height-delta.y+point.y)
        window.setFrame(NSRect(x:start.minX,y:start.maxY-height,width:width,height:height), display:true)
    }
    override func mouseUp(with event: NSEvent) { resizeStart = nil }
}

final class ClassicWindowButton: NSButton {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        let x = title == "−" ? 9 : 18
        if let image = ClassicUI.skin?.sprite("titlebar.bmp", NSRect(x: x, y: isHighlighted ? 9 : 0, width: 9, height: 9)) {
            image.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.none.rawValue])
        } else { ClassicUI.bevel(bounds, down: isHighlighted); ClassicUI.caption(title, rect: bounds, font: .systemFont(ofSize: 7)) }
    }
}
final class ClassicCheckBox: NSButton {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        let box = NSRect(x: 2, y: bounds.midY - 6, width: 12, height: 12)
        ClassicUI.black.setFill(); box.fill(); NSColor.gray.setStroke(); NSBezierPath(rect: box).stroke()
        if state == .on { ClassicUI.caption("✓", rect: box, color: ClassicUI.green) }
        ClassicUI.caption(title, rect: NSRect(x: 18, y: 0, width: bounds.width - 18, height: bounds.height), color: ClassicUI.text, alignment: .left)
    }
}
