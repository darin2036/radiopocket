import AppKit

/// Shared compact control metrics for the player’s secondary windows.
enum ClassicUI {
    static let font = NSFont(name: "Tahoma", size: 11) ?? .systemFont(ofSize: 11)
    static let small = font
    /// Station and song/artist for the shaded title bars; nothing is returned while no station is loaded.
    static var nowPlaying: () -> String? = { nil }
    /// Colours follow the skin (GENEX.BMP / PLEDIT.TXT), as Winamp's general windows do.
    static var palette: SkinPalette { skin?.palette ?? .native }
    static var panel: NSColor { palette.window }
    static var black: NSColor { palette.item }
    static var green: NSColor { palette.accent }
    static var text: NSColor { palette.text }
    static var dim: NSColor { palette.label }
    static var selection: NSColor { palette.selection }
    /// Speed of scrolling station and song text, in points per second; 0 is off.
    static var scrollSpeed: Double = 30
    static let scrollSpeeds: [(title: String, value: Double)] = [("Off", 0), ("Slow", 15), ("Normal", 30), ("Fast", 60)]
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
    /// When set, resizing keeps the content area at this width-to-height ratio (nil result: free resize).
    /// `aspectChrome` is the window space around the content, which does not scale.
    var contentAspect: (() -> CGFloat?)?
    var aspectChrome = NSSize.zero

    /// Adjusts `rect` so its content area has `contentAspect`. The height follows the width unless only the
    /// bottom edge is being dragged, in which case the width follows the height; the top-left stays put.
    func fittedToAspect(_ rect: NSRect, widthLeads: Bool) -> NSRect {
        guard let ratio = contentAspect?(), ratio > 0 else { return rect }
        var width = rect.width, height = rect.height
        if widthLeads { height = (width - aspectChrome.width) / ratio + aspectChrome.height }
        else { width = (height - aspectChrome.height) * ratio + aspectChrome.width }
        if height < minSize.height { height = minSize.height; width = (height - aspectChrome.height) * ratio + aspectChrome.width }
        if width < minSize.width { width = minSize.width; height = (width - aspectChrome.width) / ratio + aspectChrome.height }
        return NSRect(x: rect.minX, y: rect.maxY - height, width: width, height: height)
    }

    /// Double-clicking a panel's title bar shades it to the bar alone, as the player does; the full panel is kept aside.
    private var shadeRestore: (content: NSView, frame: NSRect, minSize: NSSize, autosave: String)?
    /// Width every shaded panel takes, so the bars stack under the player and equalizer at the same width.
    static var nestedShadeWidth: () -> CGFloat? = { nil }
    /// What this panel shows on its shaded bar in place of the playback controls; the close and minimize buttons stay.
    var shadeContent: ((ClassicChrome) -> Void)?
    var isShaded: Bool { shadeRestore != nil }
    func toggleShade() {
        if let saved = shadeRestore {
            shadeRestore = nil
            minSize = saved.minSize
            setFrameAutosaveName(saved.autosave)
            // The top edge stays where the bar was left, even if it was dragged while shaded.
            setFrame(NSRect(x: frame.minX, y: frame.maxY - saved.frame.height, width: saved.frame.width, height: saved.frame.height), display: false)
            contentView = saved.content
            display()
            delegate?.windowDidResize?(Notification(name: NSWindow.didResizeNotification, object: self))
        } else if let chrome = contentView as? ClassicChrome {
            shadeRestore = (chrome, frame, minSize, frameAutosaveName)
            // A shaded bar must not be remembered as the panel's size for the next launch.
            setFrameAutosaveName("")
            let width = Self.nestedShadeWidth() ?? frame.width
            let bar = ClassicChrome(frame: NSRect(origin: .zero, size: NSSize(width: width, height: ClassicChrome.shadeHeight)))
            bar.title = chrome.title; bar.shadeMinimizable = styleMask.contains(.miniaturizable); bar.shadeContent = shadeContent; bar.isShadeBar = true
            minSize = NSSize(width: min(minSize.width, width), height: ClassicChrome.shadeHeight)
            contentView = bar
            setFrame(NSRect(x: frame.minX, y: frame.maxY - ClassicChrome.shadeHeight, width: width, height: ClassicChrome.shadeHeight), display: true)
        }
    }
    override func close() {
        if isShaded { toggleShade() }
        super.close()
    }

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
    /// The display `rect` mostly sits on (the one with the largest overlap), as its usable area and its full frame.
    static func display(for rect: NSRect, fallback: NSScreen?) -> (visible: NSRect, full: NSRect)? {
        func overlap(_ s: NSScreen) -> CGFloat { let i = s.frame.intersection(rect); return i.isNull ? 0 : i.width * i.height }
        let best = NSScreen.screens.max { overlap($0) < overlap($1) }.flatMap { overlap($0) > 0 ? $0 : nil } ?? fallback ?? NSScreen.main
        return best.map { ($0.visibleFrame, $0.frame) }
    }

    /// Moves `rect` so its edges line up with the screen edges and the `others` when they come within `snapDistance`.
    /// `desktop` is the display's full frame; its edges attract too, so a panel can sit against the true screen edge
    /// as well as against the menu bar and Dock.
    static func snapped(_ rect: NSRect, to others: [NSRect], screen: NSRect, desktop: NSRect? = nil) -> NSRect {
        var best: (dx: CGFloat, dy: CGFloat) = (.infinity, .infinity)
        func consider(x: CGFloat? = nil, y: CGFloat? = nil) {
            if let x, abs(x) < abs(best.dx) { best.dx = x }
            if let y, abs(y) < abs(best.dy) { best.dy = y }
        }
        let screens = [screen] + (desktop.map { [$0] } ?? [])
        for target in screens + others {
            let isScreen = screens.contains(target)
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

    /// Pulls the edges being dragged (`x` values for left/right, `y` values for the bottom) onto the screen edges and
    /// the edges of neighbouring panels within `snapDistance`, so a resized window lines up with what it sits beside.
    func snappedResize(_ rect: NSRect, left: Bool, right: Bool, bottom: Bool) -> NSRect {
        let display = Self.display(for: rect, fallback: screen)
        let visible = display?.visible ?? rect, full = display?.full ?? rect
        var xs: [CGFloat] = [visible.minX, visible.maxX, full.minX, full.maxX], ys: [CGFloat] = [visible.minY, visible.maxY, full.minY, full.maxY]
        for other in neighbours.map(\.frame) {
            if rect.minY - Self.snapDistance < other.maxY && rect.maxY + Self.snapDistance > other.minY { xs += [other.minX, other.maxX] }
            if rect.minX - Self.snapDistance < other.maxX && rect.maxX + Self.snapDistance > other.minX { ys += [other.minY, other.maxY] }
        }
        func pull(_ value: CGFloat, _ targets: [CGFloat]) -> CGFloat {
            targets.filter { abs($0 - value) <= Self.snapDistance }.min { abs($0 - value) < abs($1 - value) } ?? value
        }
        var minX = rect.minX, maxX = rect.maxX, minY = rect.minY
        if left { minX = min(pull(minX, xs), maxX - minSize.width) }
        if right { maxX = max(pull(maxX, xs), minX + minSize.width) }
        if bottom { minY = min(pull(minY, ys), rect.maxY - minSize.height) }
        return NSRect(x: minX, y: minY, width: maxX - minX, height: rect.maxY - minY)
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
                let display = PlayerWindow.display(for: moved, fallback: screen)
                moved = PlayerWindow.snapped(moved, to: others, screen: display?.visible ?? moved, desktop: display?.full)
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
/// A drop-down arrow drawn as a pixel triangle so it centres the same way in every control.
private func dropArrow(in rect: NSRect, color: NSColor) {
    let cx = rect.midX.rounded(), cy = rect.midY.rounded()
    color.setFill()
    for i in 0..<3 { NSRect(x: cx - 3 + CGFloat(i), y: cy - 1 + CGFloat(i), width: 7 - CGFloat(i) * 2, height: 1).fill() }
}
final class ClassicPopup: NSPopUpButton {
    override var isFlipped: Bool { true }
    // The system bezel's alignment insets would make the drawn control larger than its constraints, so it would
    // stand taller than a ClassicButton and crowd its neighbours.
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }
    override func draw(_ dirtyRect: NSRect) {
        ClassicUI.button(bounds, down: isHighlighted)
        let ink = ClassicUI.buttonText.withAlphaComponent(isEnabled ? 1 : 0.4)
        ClassicUI.caption(title, rect: NSRect(x: 3, y: 0, width: bounds.width - 20, height: bounds.height), color: ink, alignment: .left)
        dropArrow(in: NSRect(x: bounds.width - 16, y: 0, width: 12, height: bounds.height), color: ink)
    }
}
class ClassicChrome: NSView {
    static let barHeight: CGFloat = 20
    /// A shaded bar matches the player's and equalizer's 14-point title bar.
    static let shadeHeight: CGFloat = 14
    var title = "MEDIA LIBRARY" { didSet { needsDisplay = true } }
    /// The stand-in a shaded window shows: just the title bar, with a mini transport and the now-playing text on it.
    var isShadeBar = false { didSet { if isShadeBar { addShadeControls() } } }
    var shadeMinimizable = false
    var shadeContent: ((ClassicChrome) -> Void)?
    private func addShadeControls() {
        var x = bounds.width - 12
        for (caption, action) in [("×", #selector(shadeClose)), ("−", #selector(shadeMinimize))] {
            if caption == "−", !shadeMinimizable { continue }
            let button = ClassicWindowButton(title: caption, target: self, action: action)
            button.isBordered = false; button.frame = NSRect(x: x, y: 3, width: 9, height: 9); button.autoresizingMask = .minXMargin
            addSubview(button); x -= 11
        }
        if let shadeContent { shadeContent(self); return }
        let transport = MiniTransport(frame: NSRect(x: 6, y: 2, width: MiniTransport.width, height: 10))
        let label = MarqueeLabel(frame: NSRect(x: 50, y: 2, width: bounds.width - 50 - 30, height: 10), font: .monospacedSystemFont(ofSize: 8, weight: .medium)) { [weak self] in ClassicUI.nowPlaying() ?? self?.title ?? "" }
        label.autoresizingMask = .width
        addSubview(transport); addSubview(label)
    }
    @objc private func shadeClose() { window?.close() }
    @objc private func shadeMinimize() { window?.miniaturize(nil) }
    private var resizeStart: (frame: NSRect, mouse: NSPoint, edges: Edges)?
    private struct Edges: OptionSet { let rawValue: Int; static let left = Edges(rawValue: 1), right = Edges(rawValue: 2), bottom = Edges(rawValue: 4) }
    private var userResizable: Bool { !isShadeBar && (window as? PlayerWindow)?.isUserResizable == true }
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
        if isShadeBar, let sheet = ClassicUI.skin {
            // The player's plain title bar (no WINAMP text or display): its two end caps with the stripes tiled between them.
            func piece(_ sx: CGFloat, _ width: CGFloat, to x: CGFloat) -> Bool {
                guard let image = sheet.sprite("titlebar.bmp", NSRect(x: sx, y: window?.isKeyWindow == false ? 15 : 0, width: width, height: 14)) else { return false }
                image.draw(in: NSRect(x: x, y: 0, width: width, height: 14), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.none.rawValue]); return true
            }
            let cap: CGFloat = 25
            var x = cap, ok = piece(27, cap, to: 0)
            while ok, x < w - cap { ok = piece(27 + cap, min(25, w - cap - x), to: x); x += 25 }
            if ok, piece(27 + 275 - cap, cap, to: w - cap) { return }
        }
        func sprite(_ source: NSRect, _ target: NSRect) -> Bool {
            guard let image = ClassicUI.skin?.sprite("gen.bmp", source) else { return false }
            image.draw(in: target, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.none.rawValue]); return true
        }
        // GEN.BMP: active title pieces on row 0 (inactive on row 21), sides at y 42, bottom corners at y 42 / 57 and filler at 127,72.
        let row: CGFloat = window?.isKeyWindow == false ? 21 : 0
        let titleFont = NSFont.monospacedSystemFont(ofSize: 9, weight: .bold)
        let textWidth = ceil((title as NSString).size(withAttributes: [.font: titleFont]).width) + 4
        let middle = isShadeBar ? max(25, w - 150) : max(25, min(w - 150, (textWidth / 25).rounded(.up) * 25))
        let titleStart = ((w - middle) / 2 - 25).rounded(.down)
        func tile(_ sx: CGFloat, _ sy: CGFloat, _ sw: CGFloat, _ sh: CGFloat, from: CGFloat, to: CGFloat, y: CGFloat) {
            var x = from
            while x < to { let width = min(sw, to - x); _ = sprite(NSRect(x: sx, y: sy, width: width, height: sh), NSRect(x: x, y: y, width: width, height: sh)); x += width }
        }
        if sprite(NSRect(x: 0, y: row, width: 25, height: 20), NSRect(x: 0, y: 0, width: 25, height: 20)) {
            if isShadeBar {
                // A shaded bar has its own content, so it gets the plain title-bar filler without the skin's logo pieces.
                tile(104, row, 25, 20, from: 25, to: w - 25, y: 0)
            } else {
            tile(104, row, 25, 20, from: 25, to: titleStart, y: 0)
            _ = sprite(NSRect(x: 26, y: row, width: 25, height: 20), NSRect(x: titleStart, y: 0, width: 25, height: 20))
            tile(52, row, 25, 20, from: titleStart + 25, to: titleStart + 25 + middle, y: 0)
            _ = sprite(NSRect(x: 78, y: row, width: 25, height: 20), NSRect(x: titleStart + 25 + middle, y: 0, width: 25, height: 20))
            tile(104, row, 25, 20, from: titleStart + 50 + middle, to: w - 25, y: 0)
            }
            _ = sprite(NSRect(x: 130, y: row, width: 25, height: 20), NSRect(x: w - 25, y: 0, width: 25, height: 20))
            var y: CGFloat = 20
            while !isShadeBar, y < h - 14 {
                let height = min(29, h - 14 - y)
                _ = sprite(NSRect(x: 127, y: 42, width: 11, height: height), NSRect(x: 0, y: y, width: 11, height: height))
                _ = sprite(NSRect(x: 139, y: 42, width: 8, height: height), NSRect(x: w - 8, y: y, width: 8, height: height))
                y += height
            }
            let corner = min(125, w / 2)
            if !isShadeBar {
            _ = sprite(NSRect(x: 0, y: 42, width: corner, height: 14), NSRect(x: 0, y: h - 14, width: corner, height: 14))
            // The filler's 14th row (y 85) is the sheet's cyan divider: draw its 13 real rows 1:1 so its lines meet the
            // corners' lines, and take the last row from the corners' own last row.
            var fx = corner
            while fx < w - corner {
                let width = min(25, w - corner - fx)
                _ = sprite(NSRect(x: 127, y: 72, width: width, height: 13), NSRect(x: fx, y: h - 14, width: width, height: 13)); fx += width
            }
            _ = sprite(NSRect(x: corner - 1, y: 55, width: 1, height: 1), NSRect(x: corner, y: h - 1, width: max(0, w - 2 * corner), height: 1))
            _ = sprite(NSRect(x: 125 - corner, y: 57, width: corner, height: 14), NSRect(x: w - corner, y: h - 14, width: corner, height: 14))
            }
            let titleColor = ClassicUI.skin?.genTitleColor ?? ClassicUI.text
            if !isShadeBar { ClassicUI.caption(title, rect: NSRect(x: titleStart + 22, y: 3, width: middle + 6, height: 12), color: titleColor, font: titleFont) }
        } else {
            for y in [4, 7, 10, 13] { NSColor(white: 0.55, alpha: 1).setFill(); NSRect(x: 8, y: CGFloat(y), width: w - 16, height: 1).fill() }
            if !isShadeBar {
                let tw = min(w - 90, CGFloat(title.count * 7 + 20))
                let label = NSRect(x: (w - tw)/2, y: 2, width: tw, height: 16)
                ClassicUI.panel.setFill(); label.fill()
                ClassicUI.caption(title, rect: label, color: ClassicUI.text, font: .monospacedSystemFont(ofSize: 10, weight: .bold))
            }
        }
        ClassicUI.dim.setStroke()
        if userResizable { for i in 0..<3 { let p = NSBezierPath(); p.move(to: NSPoint(x: w-5-CGFloat(i*3), y: h-4)); p.line(to: NSPoint(x:w-4,y:h-5-CGFloat(i*3))); p.stroke() } }
    }
    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let hit = edges(at: p)
        if !hit.isEmpty, let window { resizeStart = (window.frame, NSEvent.mouseLocation, hit) }
        else if p.y < Self.barHeight {
            if event.clickCount == 2 { (window as? PlayerWindow)?.toggleShade() }
            else { (window as? PlayerWindow)?.trackDrag(event) }
        }
    }
    override func mouseDragged(with event: NSEvent) {
        guard let (start, point, edges) = resizeStart, let window else { return }
        let now = NSEvent.mouseLocation
        let dx = now.x - point.x, dy = now.y - point.y
        var x = start.minX, width = start.width, height = start.height
        if edges.contains(.right) { width = max(window.minSize.width, start.width + dx) }
        if edges.contains(.left) { width = max(window.minSize.width, start.width - dx); x = start.maxX - width }
        if edges.contains(.bottom) { height = max(window.minSize.height, start.height - dy) }
        var frame = NSRect(x: x, y: start.maxY - height, width: width, height: height)
        if !event.modifierFlags.contains(.option), let player = window as? PlayerWindow {
            frame = player.snappedResize(frame, left: edges.contains(.left), right: edges.contains(.right), bottom: edges.contains(.bottom))
        }
        if let player = window as? PlayerWindow {
            let horizontal = edges.contains(.left) || edges.contains(.right)
            frame = player.fittedToAspect(frame, widthLeads: horizontal)
            // Dragging the left edge keeps the right edge fixed.
            if edges.contains(.left) { frame.origin.x = start.maxX - frame.width }
        }
        window.setFrame(frame, display: true)
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
