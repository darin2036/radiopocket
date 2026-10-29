import AppKit

/// Shared compact control metrics for the player’s secondary windows.
enum ClassicUI {
    static let font = NSFont(name: "Tahoma", size: 11) ?? .systemFont(ofSize: 11)
    static let small = font
    /// Colours follow the skin (GENEX.BMP / PLEDIT.TXT), as Winamp's general windows do.
    static var palette: SkinPalette { skin?.palette ?? .native }
    static var panel: NSColor { palette.window }
    static var black: NSColor { palette.item }
    static var green: NSColor { palette.accent }
    static var text: NSColor { palette.text }
    static var dim: NSColor { palette.label }
    static var selection: NSColor { palette.selection }
    static var skin: ClassicSkin? { didSet {
        let old = oldValue?.palette ?? .native, new = palette
        for window in NSApp.windows { if let content = window.contentView { recolor(content, from: old, to: new) } }
    } }
    /// Views built with the previous skin's colours take the new skin's equivalents; tables rebuild their cells.
    private static func recolor(_ view: NSView, from old: SkinPalette, to new: SkinPalette) {
        func map(_ color: NSColor?) -> NSColor? {
            guard let color else { return nil }
            for (before, after) in [(old.text, new.text), (old.label, new.label), (old.accent, new.accent), (old.item, new.item), (old.window, new.window)] where color == before { return after }
            return nil
        }
        if let field = view as? NSTextField {
            if let color = map(field.textColor) { field.textColor = color }
            if let color = map(field.backgroundColor) { field.backgroundColor = color }
        }
        if let scroll = view as? NSScrollView, let color = map(scroll.backgroundColor) { scroll.backgroundColor = color }
        if let table = view as? NSTableView {
            if let color = map(table.backgroundColor) { table.backgroundColor = color }
            table.reloadData()
        }
        view.needsDisplay = true
        view.subviews.forEach { recolor($0, from: old, to: new) }
    }
    static func bevel(_ rect: NSRect, down: Bool = false) {
        NSColor(white: down ? 0.46 : 0.68, alpha: 1).setFill(); rect.fill()
        (down ? NSColor(white: 0.14, alpha: 1) : NSColor(white: 0.90, alpha: 1)).setFill()
        NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: 1).fill()
        NSRect(x: rect.minX, y: rect.minY, width: 1, height: rect.height).fill()
        (down ? NSColor(white: 0.90, alpha: 1) : NSColor(white: 0.14, alpha: 1)).setFill()
        NSRect(x: rect.minX, y: rect.maxY - 1, width: rect.width, height: 1).fill()
        NSRect(x: rect.maxX - 1, y: rect.minY, width: 1, height: rect.height).fill()
    }
    /// A Winamp 5 general-window button: GENEX.BMP's 47 × 15 button (pressed one row down) stretched with 4-pixel edges.
    static func button(_ rect: NSRect, down: Bool = false) {
        guard let skin, skin.sprite("genex.bmp", NSRect(x: 0, y: 16, width: 47, height: 15)) != nil else { bevel(rect, down: down); return }
        let top: CGFloat = down ? 16 : 0, e: CGFloat = 4
        let columns: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [(0, e, rect.minX, e), (e, 47 - 2 * e, rect.minX + e, rect.width - 2 * e), (47 - e, e, rect.maxX - e, e)]
        let rows: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [(0, e, rect.minY, e), (e, 15 - 2 * e, rect.minY + e, rect.height - 2 * e), (15 - e, e, rect.maxY - e, e)]
        for (sx, sw, dx, dw) in columns where dw > 0 { for (sy, sh, dy, dh) in rows where dh > 0 {
            skin.sprite("genex.bmp", NSRect(x: sx, y: top + sy, width: sw, height: sh))?.draw(in: NSRect(x: dx, y: dy, width: dw, height: dh), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.none.rawValue])
        } }
    }
    static var buttonText: NSColor { skin?.buttonText ?? NSColor(white: 0.07, alpha: 1) }
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

final class PlayerWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    /// The player, equalizer and any other panels share one layer: raising one raises them all, so another
    /// app's window can never end up between two panels.
    override func becomeKey() {
        super.becomeKey()
        for other in neighbours { other.orderFront(nil) }
        orderFront(nil)
    }
    /// Resizing is handled by `ClassicChrome`, not the system mask: a `.resizable` borderless window reserves
    /// an edge strip that swallows clicks on the title-bar buttons.
    var isUserResizable = false

    static let snapDistance: CGFloat = 12
    /// The windows other windows snap to: the other visible RadioPocket panels.
    private var neighbours: [PlayerWindow] { NSApp.windows.compactMap { $0 as? PlayerWindow }.filter { $0 !== self && $0.isVisible } }

    /// Windows whose edge touches `frame` (directly or through other docked windows). Used to carry the player's
    /// equalizer and library along with it, as Winamp's docked windows do.
    private func dockedGroup() -> [PlayerWindow] {
        var group: [PlayerWindow] = [], edge = [frame], pool = neighbours
        while let reference = edge.popLast() {
            for other in pool where PlayerWindow.touching(reference, other.frame) {
                group.append(other); edge.append(other.frame); pool.removeAll { $0 === other }
            }
        }
        return group
    }
    static func touching(_ a: NSRect, _ b: NSRect) -> Bool {
        let tolerance: CGFloat = 3
        let overlapX = min(a.maxX, b.maxX) - max(a.minX, b.minX) > 4, overlapY = min(a.maxY, b.maxY) - max(a.minY, b.minY) > 4
        let sideBySide = (abs(a.maxX - b.minX) <= tolerance || abs(b.maxX - a.minX) <= tolerance) && overlapY
        let stacked = (abs(a.maxY - b.minY) <= tolerance || abs(b.maxY - a.minY) <= tolerance) && overlapX
        return sideBySide || stacked
    }

    /// Moves `rect` so its edges line up with the screen edges and the `others` when they come within `snapDistance`.
    static func snapped(_ rect: NSRect, to others: [NSRect], screen: NSRect) -> NSRect {
        var best: (dx: CGFloat, dy: CGFloat) = (.infinity, .infinity)
        func consider(x: CGFloat? = nil, y: CGFloat? = nil) {
            if let x, abs(x) < abs(best.dx) { best.dx = x }
            if let y, abs(y) < abs(best.dy) { best.dy = y }
        }
        for target in [screen] + others {
            let isScreen = target == screen
            let nearY = rect.minY - snapDistance < target.maxY && rect.maxY + snapDistance > target.minY
            let nearX = rect.minX - snapDistance < target.maxX && rect.maxX + snapDistance > target.minX
            if isScreen || nearY {
                consider(x: target.minX - rect.minX); consider(x: target.maxX - rect.maxX)
                if !isScreen { consider(x: target.maxX - rect.minX); consider(x: target.minX - rect.maxX) }
            }
            if isScreen || nearX {
                consider(y: target.minY - rect.minY); consider(y: target.maxY - rect.maxY)
                if !isScreen { consider(y: target.maxY - rect.minY); consider(y: target.minY - rect.maxY) }
            }
        }
        var result = rect
        if abs(best.dx) <= snapDistance { result.origin.x += best.dx }
        if abs(best.dy) <= snapDistance { result.origin.y += best.dy }
        return result
    }

    /// Drags the window by its title strip with Winamp-style snapping. Hold Option to move freely. With
    /// `movesDockedWindows` (the player), anything docked to it moves too.
    func trackDrag(_ event: NSEvent, movesDockedWindows: Bool = false) {
        let startMouse = NSEvent.mouseLocation
        let followers = movesDockedWindows ? dockedGroup() : []
        let starts = ([self] + followers).map { ($0, $0.frame) }
        let group = starts.map(\.1).reduce(NSRect.null) { $0.union($1) }
        let others = neighbours.filter { window in !followers.contains { $0 === window } }.map(\.frame)
        while let next = nextEvent(matching: [.leftMouseDragged, .leftMouseUp], until: .distantFuture, inMode: .eventTracking, dequeue: true) {
            if next.type == .leftMouseUp { break }
            let now = NSEvent.mouseLocation
            var moved = group.offsetBy(dx: now.x - startMouse.x, dy: now.y - startMouse.y)
            if !next.modifierFlags.contains(.option) {
                let screen = (NSScreen.screens.first { $0.frame.intersects(moved) } ?? screen ?? NSScreen.main)?.visibleFrame ?? moved
                moved = PlayerWindow.snapped(moved, to: others, screen: screen)
            }
            let dx = moved.minX - group.minX, dy = moved.minY - group.minY
            for (window, frame) in starts { window.setFrameOrigin(NSPoint(x: frame.minX + dx, y: frame.minY + dy)) }
        }
    }
}

class ClassicButton: NSButton {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        ClassicUI.button(bounds, down: isHighlighted)
        ClassicUI.caption(title, rect: bounds.offsetBy(dx: isHighlighted ? 1 : 0, dy: isHighlighted ? 1 : 0), color: ClassicUI.buttonText.withAlphaComponent(isEnabled ? 1 : 0.4))
        if window?.firstResponder === self { NSColor.darkGray.setStroke(); NSBezierPath(rect: bounds.insetBy(dx: 3, dy: 3)).stroke() }
    }
}
final class ClassicPopup: NSPopUpButton {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        ClassicUI.button(bounds, down: isHighlighted)
        ClassicUI.caption(title, rect: NSRect(x: 2, y: 0, width: bounds.width - 17, height: bounds.height), color: ClassicUI.buttonText.withAlphaComponent(isEnabled ? 1 : 0.4), alignment: .left)
        ClassicUI.caption("▾", rect: NSRect(x: bounds.width - 18, y: 0, width: 17, height: bounds.height), color: ClassicUI.buttonText)
    }
}
final class ClassicCombo: NSComboBox {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        ClassicUI.black.setFill(); bounds.fill()
        NSColor.gray.setStroke(); NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5)).stroke()
        ClassicUI.caption(stringValue, rect: NSRect(x: 1, y: 0, width: bounds.width - 19, height: bounds.height), color: isEnabled ? ClassicUI.text : ClassicUI.dim, alignment: .left)
        let arrow = NSRect(x: bounds.width - 18, y: 0, width: 18, height: bounds.height)
        ClassicUI.button(arrow); ClassicUI.caption("▾", rect: arrow, color: ClassicUI.buttonText)
    }
}

class ClassicChrome: NSView {
    var title = "MEDIA LIBRARY" { didSet { needsDisplay = true } }
    private var resizeStart: (frame: NSRect, mouse: NSPoint, edges: Edges)?
    private struct Edges: OptionSet { let rawValue: Int; static let left = Edges(rawValue: 1), right = Edges(rawValue: 2), bottom = Edges(rawValue: 4) }
    private var userResizable: Bool { (window as? PlayerWindow)?.isUserResizable == true }
    /// Left, right and bottom edges plus the bottom-right grip. The top edge is left alone so the title buttons stay clickable.
    private func edges(at p: NSPoint) -> Edges {
        guard userResizable else { return [] }
        var e: Edges = []
        if p.x < 4 && p.y > 20 { e.insert(.left) }
        if p.x > bounds.maxX - 4 && p.y > 20 { e.insert(.right) }
        if p.y > bounds.maxY - 4 { e.insert(.bottom) }
        if p.x > bounds.maxX - 18 && p.y > bounds.maxY - 18 { e.formUnion([.right, .bottom]) }
        return e
    }
    override func resetCursorRects() {
        guard userResizable else { return }
        let b = bounds
        addCursorRect(NSRect(x: 0, y: 20, width: 4, height: b.height - 24), cursor: .resizeLeftRight)
        addCursorRect(NSRect(x: b.maxX - 4, y: 20, width: 4, height: b.height - 24), cursor: .resizeLeftRight)
        addCursorRect(NSRect(x: 4, y: b.maxY - 4, width: b.width - 22, height: 4), cursor: .resizeUpDown)
        addCursorRect(NSRect(x: b.maxX - 18, y: b.maxY - 18, width: 18, height: 18), cursor: .crosshair)
    }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        ClassicUI.panel.setFill(); bounds.fill()
        NSColor.gray.setStroke(); NSBezierPath(rect: bounds.insetBy(dx: 1, dy: 1)).stroke()
        let h = bounds.height, w = bounds.width
        func sprite(_ source: NSRect, _ target: NSRect) -> Bool {
            guard let image = ClassicUI.skin?.sprite("gen.bmp", source) else { return false }
            image.draw(in: target, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.none.rawValue]); return true
        }
        // GEN.BMP: active title pieces on row 0 (inactive on row 21), sides at y 42, bottom corners at y 42 / 57 and filler at 127,72.
        let row: CGFloat = window?.isKeyWindow == false ? 21 : 0
        let titleFont = NSFont.monospacedSystemFont(ofSize: 9, weight: .bold)
        let textWidth = ceil((title as NSString).size(withAttributes: [.font: titleFont]).width) + 4
        let middle = max(25, min(w - 150, (textWidth / 25).rounded(.up) * 25))
        let titleStart = ((w - middle) / 2 - 25).rounded(.down)
        func tile(_ sx: CGFloat, _ sy: CGFloat, _ sw: CGFloat, _ sh: CGFloat, from: CGFloat, to: CGFloat, y: CGFloat) {
            var x = from
            while x < to { let width = min(sw, to - x); _ = sprite(NSRect(x: sx, y: sy, width: width, height: sh), NSRect(x: x, y: y, width: width, height: sh)); x += width }
        }
        if sprite(NSRect(x: 0, y: row, width: 25, height: 20), NSRect(x: 0, y: 0, width: 25, height: 20)) {
            tile(104, row, 25, 20, from: 25, to: titleStart, y: 0)
            _ = sprite(NSRect(x: 26, y: row, width: 25, height: 20), NSRect(x: titleStart, y: 0, width: 25, height: 20))
            tile(52, row, 25, 20, from: titleStart + 25, to: titleStart + 25 + middle, y: 0)
            _ = sprite(NSRect(x: 78, y: row, width: 25, height: 20), NSRect(x: titleStart + 25 + middle, y: 0, width: 25, height: 20))
            tile(104, row, 25, 20, from: titleStart + 50 + middle, to: w - 25, y: 0)
            _ = sprite(NSRect(x: 130, y: row, width: 25, height: 20), NSRect(x: w - 25, y: 0, width: 25, height: 20))
            var y: CGFloat = 20
            while y < h - 14 {
                let height = min(29, h - 14 - y)
                _ = sprite(NSRect(x: 127, y: 42, width: 11, height: height), NSRect(x: 0, y: y, width: 11, height: height))
                _ = sprite(NSRect(x: 139, y: 42, width: 8, height: height), NSRect(x: w - 8, y: y, width: 8, height: height))
                y += height
            }
            let corner = min(125, w / 2)
            _ = sprite(NSRect(x: 0, y: 42, width: corner, height: 14), NSRect(x: 0, y: h - 14, width: corner, height: 14))
            tile(127, 72, 25, 14, from: corner, to: w - corner, y: h - 14)
            _ = sprite(NSRect(x: 125 - corner, y: 57, width: corner, height: 14), NSRect(x: w - corner, y: h - 14, width: corner, height: 14))
            let titleColor = ClassicUI.skin?.genTitleColor ?? ClassicUI.text
            ClassicUI.caption(title, rect: NSRect(x: titleStart + 22, y: 3, width: middle + 6, height: 12), color: titleColor, font: titleFont)
        } else {
            for y in [4, 7, 10, 13] { NSColor(white: 0.55, alpha: 1).setFill(); NSRect(x: 8, y: CGFloat(y), width: w - 16, height: 1).fill() }
            let tw = min(w - 90, CGFloat(title.count * 7 + 20))
            let label = NSRect(x: (w - tw)/2, y: 2, width: tw, height: 16)
            ClassicUI.panel.setFill(); label.fill()
            ClassicUI.caption(title, rect: label, color: ClassicUI.text, font: .monospacedSystemFont(ofSize: 10, weight: .bold))
        }
        ClassicUI.dim.setStroke()
        if userResizable { for i in 0..<3 { let p = NSBezierPath(); p.move(to: NSPoint(x: w-5-CGFloat(i*3), y: h-4)); p.line(to: NSPoint(x:w-4,y:h-5-CGFloat(i*3))); p.stroke() } }
    }
    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let hit = edges(at: p)
        if !hit.isEmpty, let window { resizeStart = (window.frame, NSEvent.mouseLocation, hit) }
        else if p.y < 20 { (window as? PlayerWindow)?.trackDrag(event) }
    }
    override func mouseDragged(with event: NSEvent) {
        guard let (start, point, edges) = resizeStart, let window else { return }
        let now = NSEvent.mouseLocation
        let dx = now.x - point.x, dy = now.y - point.y
        var x = start.minX, width = start.width, height = start.height
        if edges.contains(.right) { width = max(window.minSize.width, start.width + dx) }
        if edges.contains(.left) { width = max(window.minSize.width, start.width - dx); x = start.maxX - width }
        if edges.contains(.bottom) { height = max(window.minSize.height, start.height - dy) }
        window.setFrame(NSRect(x: x, y: start.maxY - height, width: width, height: height), display: true)
    }
    override func mouseUp(with event: NSEvent) { resizeStart = nil }
}

final class ClassicWindowButton: NSButton {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        // General windows close with GEN.BMP's button; minimize has no GEN.BMP art, so it borrows the main title bar's.
        let source = title == "−" ? ("titlebar.bmp", NSRect(x: 9, y: isHighlighted ? 9 : 0, width: 9, height: 9))
                                  : ("gen.bmp", NSRect(x: 148, y: isHighlighted ? 51 : 42, width: 9, height: 9))
        if let image = ClassicUI.skin?.sprite(source.0, source.1) {
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
