import AppKit

final class PixelButton: NSButton {
    var paint: ((NSRect, Bool) -> Void)?
    override func draw(_ dirtyRect: NSRect) { NSGraphicsContext.current?.imageInterpolation = .none; paint?(bounds, isHighlighted) }
    override var isFlipped: Bool { true }
}

final class PlayerView: NSView {
    let engine: RadioEngine
    var skin: ClassicSkin? { didSet { ClassicUI.skin = skin; needsDisplay = true; controls.forEach { $0.needsDisplay = true } } }
    var shaded = false { didSet {
        controls.forEach { $0.isHidden = shaded && $0.frame.minY >= 14 }; needsDisplay = true
    } }
    var action: ((String) -> Void)?
    var volumeChanged: ((Float) -> Void)?
    var balanceChanged: ((Float) -> Void)?
    private static let balanceSlot = NSRect(x: 177, y: 57, width: 38, height: 16)
    private(set) var visuals: VisualizerController?
    private var controls: [PixelButton] = []
    private var trackingVolume = false
    private var trackingBalance = false
    private var green: NSColor { skin?.displayForeground ?? NSColor(calibratedRed: 0.68, green: 0.96, blue: 0.39, alpha: 1) }
    private var ink: NSColor { skin?.displayBackground ?? NSColor(calibratedRed: 0.04, green: 0.065, blue: 0.065, alpha: 1) }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    init(engine: RadioEngine) {
        self.engine = engine
        super.init(frame: NSRect(x: 0, y: 0, width: 550, height: 232))
        setBoundsSize(NSSize(width: 275, height: 116))
        registerForDraggedTypes([.fileURL])
        let transport: [(String, String)] = [("previous", "Previous favorite"), ("play", "Play live stream"), ("pause", "Pause"), ("stop", "Stop"), ("next", "Next favorite")]
        for (i, entry) in transport.enumerated() {
            add(entry.0, label: entry.1, rect: NSRect(x: 16 + i * 23, y: 88, width: i == 4 ? 22 : 23, height: 18)) { [weak self] rect, down in
                guard let self else { return }
                if !self.drawSprite("cbuttons.bmp", NSRect(x: i * 23, y: down ? 18 : 0, width: i == 4 ? 22 : 23, height: 18), in: rect) {
                    self.bevel(rect, down: down)
                    self.transportIcon(i, in: rect, down: down)
                }
            }
        }
        add("open", label: "Open stream URL", rect: NSRect(x: 136, y: 89, width: 22, height: 16)) { [weak self] rect, down in
            guard let self else { return }
            if !self.drawSprite("cbuttons.bmp", NSRect(x: 114, y: down ? 16 : 0, width: 22, height: 16), in: rect) {
                self.bevel(rect, down: down); self.ejectIcon(in: rect, down: down)
            }
        }
        // EQ and PL live in shufrep.bmp, as in classic Winamp. PL opens the station library in place of a playlist.
        for (id, label, rect, spriteX) in [
            ("equalizer", "Show equalizer", NSRect(x: 219, y: 58, width: 23, height: 12), 0),
            ("discovery", "Browse internet radio library", NSRect(x: 242, y: 58, width: 23, height: 12), 23)
        ] {
            add(id, label: label, rect: rect) { [weak self] rect, down in
                guard let self else { return }
                if self.drawSprite("shufrep.bmp", NSRect(x: spriteX + (down ? 46 : 0), y: 61, width: 23, height: 12), in: rect) { return }
                ClassicUI.bevel(rect, down: down)
                ClassicUI.caption(id == "equalizer" ? "EQ" : "PL", rect: rect.offsetBy(dx: down ? 1 : 0, dy: down ? 1 : 0), font: .monospacedSystemFont(ofSize: 6, weight: .semibold))
            }
        }
        for (id, label, caption, x) in [("menu", "Player menu", "≡", 6), ("minimize", "Minimize", "−", 244), ("shade", "Toggle compact title bar", "▱", 254), ("close", "Close player and stop radio", "×", 264)] {
            add(id, label: label, rect: NSRect(x: x, y: 3, width: 9, height: 9)) { [weak self] rect, down in
                guard let self else { return }
                let spriteX = id == "menu" ? 0 : (id == "minimize" ? 9 : (id == "shade" ? (down ? 9 : 0) : 18))
                let spriteY = id == "shade" ? 18 : (down ? 9 : 0)
                if !self.drawSprite("titlebar.bmp", NSRect(x: spriteX, y: spriteY, width: 9, height: 9), in: rect) {
                    self.fill(rect, NSColor(white: down ? 0.18 : 0.37, alpha: 1))
                    self.text(caption, at: NSPoint(x: 2, y: -1), size: 9, color: .white)
                }
            }
        }
        addToolTip(NSRect(x: 107, y: 57, width: 68, height: 15), owner: "Volume — click or drag" as NSString, userData: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Connects the mini visualizer. It draws, and the display timer runs, only while this view is on screen.
    func attach(visuals: VisualizerController) {
        self.visuals = visuals
        visuals.hub.register(owner: self, visible: { [weak self] in
            guard let self, !self.shaded, self.visuals?.hub.settings.mini != .off else { return false }
            return VisualizerHub.windowVisible(self.window)
        }, redraw: { [weak self] in self?.setNeedsDisplay(VisDraw.miniSlot) })
        visuals.hub.observeSettings { [weak self] _ in self?.needsDisplay = true }
        addToolTip(VisDraw.miniSlot, owner: "Visualizer — click to open the visualization window, double-click for full screen, right-click for options" as NSString, userData: nil)
    }
    private var showsMiniVisualizer: Bool { !shaded && visuals?.hub.settings.mini != .off && visuals?.hub.hasSignal() == true }

    private func add(_ id: String, label: String, rect: NSRect, paint: @escaping (NSRect, Bool) -> Void) {
        let button = PixelButton(frame: rect)
        button.identifier = NSUserInterfaceItemIdentifier(id)
        button.title = ""
        button.setButtonType(.momentaryPushIn)
        button.isBordered = false
        button.focusRingType = .exterior
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.target = self
        button.action = #selector(clicked(_:))
        button.paint = paint
        controls.append(button)
        addSubview(button)
    }
    @objc private func clicked(_ sender: NSButton) { action?(sender.identifier!.rawValue) }

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.current?.imageInterpolation = .none
        // Visualizer ticks invalidate only their slot; repaint just that when nothing else changed.
        if let visuals, showsMiniVisualizer, VisDraw.miniSlot.insetBy(dx: -1, dy: -1).contains(dirtyRect) { VisDraw.mini(visuals.hub); return }
        fill(bounds, NSColor(calibratedRed: 0.19, green: 0.20, blue: 0.25, alpha: 1))
        if !drawSprite("main.bmp", NSRect(x: 0, y: 0, width: 275, height: 116), in: NSRect(x: 0, y: 0, width: 275, height: 116)) {
            frame(NSRect(x: 0, y: 0, width: 275, height: 116))
            for y in stride(from: 3, through: 11, by: 2) { fill(NSRect(x: 20, y: y, width: 220, height: 1), NSColor(white: 0.38, alpha: 1)) }
            fill(NSRect(x: 85, y: 2, width: 108, height: 11), NSColor(white: 0.19, alpha: 1))
            text("R A D I O P O C K E T", at: NSPoint(x: 89, y: 3), size: 7, color: NSColor(white: 0.85, alpha: 1))
        } else {
            _ = drawSprite("titlebar.bmp", NSRect(x: 27, y: 0, width: 275, height: 14), in: NSRect(x: 0, y: 0, width: 275, height: 14))
        }
        if shaded { return }
        if skin == nil { fill(NSRect(x: 24, y: 24, width: 76, height: 17), ink) }
        if skin == nil { fill(NSRect(x: 111, y: 24, width: 154, height: 12), ink) }
        let minutes = min(engine.elapsed / 60, 99)
        let digits = String(format: "%02d%02d", minutes, engine.elapsed % 60)
        for (i, digit) in digits.enumerated() {
            let x = [48, 60, 78, 90][i]
            if !drawSprite(skin?.sprite("nums_ex.bmp", NSRect(x: 0, y: 0, width: 9, height: 13)) != nil ? "nums_ex.bmp" : "numbers.bmp", NSRect(x: Int(String(digit))! * 9, y: 0, width: 9, height: 13), in: NSRect(x: x, y: 26, width: 9, height: 13)) {
                text(String(digit), at: NSPoint(x: x, y: 23), size: 14, color: green)
            }
        }
        if skin == nil { text(":", at: NSPoint(x: 71, y: 24), size: 12, color: green) }
        let indicator = engine.status == .playing ? 0 : engine.status == .paused ? 9 : 18
        if !drawSprite("playpaus.bmp", NSRect(x: indicator, y: 0, width: 9, height: 9), in: NSRect(x: 24, y: 28, width: 9, height: 9)) {
            fill(NSRect(x: 24, y: 29, width: 5, height: 5), engine.status == .playing ? green : .darkGray)
        }
        if let visuals, showsMiniVisualizer { VisDraw.mini(visuals.hub) } else {
            if skin == nil { fill(NSRect(x: 24, y: 43, width: 76, height: 16), ink) }
            // Winamp leaves this slot to the visualizer; skins get no status caption, the play indicator covers it.
            if skin == nil { bitmapText(engine.status.rawValue, rect: NSRect(x: 26, y: 48, width: 70, height: 6)) }
        }
        
        bitmapText(engine.title, rect: NSRect(x: 111, y: 27, width: 154, height: 6))
        // Keep the skin’s kbps/kHz/channel labels intact; unavailable values are not invented.
        // Measured from the live connection; shown as dashes until the stream has told us.
        let info = engine.status == .playing || engine.status == .paused ? engine.streamInfo : nil
        bitmapText(info?.kbps.map { String(min($0, 999)) } ?? "---", rect: NSRect(x: 111, y: 43, width: 15, height: 6))
        bitmapText(info.map { String(Int(($0.sampleRate / 1000).rounded())) } ?? "--", rect: NSRect(x: 156, y: 43, width: 10, height: 6))
        if let info {
            let stereo = info.channels > 1
            _ = drawSprite("monoster.bmp", NSRect(x: 29, y: stereo ? 12 : 0, width: 27, height: 12), in: NSRect(x: 212, y: 41, width: 27, height: 12))
            _ = drawSprite("monoster.bmp", NSRect(x: 0, y: stereo ? 0 : 12, width: 29, height: 12), in: NSRect(x: 239, y: 41, width: 29, height: 12))
        } else {
            _ = drawSprite("monoster.bmp", NSRect(x: 29, y: 12, width: 27, height: 12), in: NSRect(x: 212, y: 41, width: 27, height: 12))
            _ = drawSprite("monoster.bmp", NSRect(x: 0, y: 12, width: 29, height: 12), in: NSRect(x: 239, y: 41, width: 29, height: 12))
        }
        if skin == nil { fill(NSRect(x: 177, y: 57, width: 38, height: 13), ink) }
        let volume = CGFloat(engine.player.volume)
        if !drawSprite("volume.bmp", NSRect(x: 0, y: Int(volume * 27) * 15, width: 68, height: 13), in: NSRect(x: 107, y: 57, width: 68, height: 13)) {
            for i in 0..<18 { fill(NSRect(x: 110 + i * 3, y: 62, width: 2, height: 5), CGFloat(i) / 18 < volume ? green : NSColor(white: 0.20, alpha: 1)) }
        }
        _ = drawSprite("volume.bmp", NSRect(x: 15, y: 422, width: 14, height: 11), in: NSRect(x: 107 + (51 * volume).rounded(), y: 58, width: 14, height: 11))
        let balance = CGFloat(engine.balance)
        if !drawSprite("balance.bmp", NSRect(x: 9, y: Int((abs(balance) * 27).rounded()) * 15, width: 38, height: 13), in: NSRect(x: 177, y: 57, width: 38, height: 13)) {
            // Winamp's groove: a sunken channel lit end to end, green at center and shifting to red toward either side.
            var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0
            (green.usingColorSpace(.deviceRGB) ?? green).getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: nil)
            let lit = NSColor(hue: hue * (1 - abs(balance)), saturation: saturation, brightness: brightness, alpha: 1)
            fill(NSRect(x: 178, y: 60, width: 36, height: 1), NSColor(white: 0.06, alpha: 1))
            fill(NSRect(x: 178, y: 61, width: 36, height: 4), lit)
            fill(NSRect(x: 178, y: 65, width: 36, height: 1), NSColor(white: 0.45, alpha: 1))
        }
        let balanceThumb = NSRect(x: 177 + ((balance + 1) * 12).rounded(), y: 58, width: 14, height: 11)
        if !drawSprite("balance.bmp", NSRect(x: 15, y: 422, width: 14, height: 11), in: balanceThumb) {
            // Raised grey thumb with Winamp's three grip lines.
            bevel(balanceThumb, down: false)
            for dx in [-2, 0, 2] { fill(NSRect(x: balanceThumb.midX - 1 + CGFloat(dx), y: 61, width: 1, height: 5), NSColor(white: 0.25, alpha: 1)) }
        }
        // Classic skins draw their balance slider here; only the native theme has room for the readout.
        if skin == nil { fill(NSRect(x: 16, y: 72, width: 248, height: 10), ink) }
        let showsDetail = [.failed, .connecting, .paused].contains(engine.status) || (engine.status == .playing && engine.delay >= 2)
        // Classic skins have no info strip here; only the native theme draws one.
        if skin == nil { bitmapText(showsDetail ? engine.detail : engine.station?.name ?? "", rect: NSRect(x: 19, y: 74, width: 240, height: 6)) }
        
        toolTip = "\(engine.title)\n\(engine.detail)"
    }

    private func bitmapText(_ value: String, rect: NSRect) {
        NSGraphicsContext.saveGraphicsState(); rect.clip()
        let capacity = Int(rect.width / 5)
        var chars = Array(value.prefix(capacity))
        if value.count > capacity, capacity > 0 { chars[capacity - 1] = "…" }
        if let skin, chars.allSatisfy({ skin.glyph($0) != nil }) {
            for (i, char) in chars.enumerated() {
                skin.glyph(char)?.draw(in: NSRect(x: rect.minX + CGFloat(i * 5), y: rect.minY, width: 5, height: 6), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.none.rawValue])
            }
        } else {
            // Native glyphs need their full ascender/descender box, not a six-pixel crop.
            NSGraphicsContext.restoreGraphicsState()
            let height: CGFloat = rect.minY == 27 ? 12 : 10
            let box = NSRect(x: rect.minX, y: rect.minY - (height - 6) / 2, width: rect.width, height: height)
            NSGraphicsContext.saveGraphicsState(); box.clip()
            ClassicUI.caption(value, rect: box, color: green, font: .systemFont(ofSize: 7), alignment: .left)
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    @discardableResult private func drawSprite(_ sheet: String, _ source: NSRect, in target: NSRect) -> Bool {
        guard let image = skin?.sprite(sheet, source) else { return false }
        image.draw(in: target, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.none.rawValue])
        return true
    }
    private func fill(_ rect: NSRect, _ color: NSColor) { color.setFill(); rect.fill() }
    private func frame(_ rect: NSRect) {
        fill(NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: 1), NSColor(white: 0.66, alpha: 1))
        fill(NSRect(x: rect.minX, y: rect.minY, width: 1, height: rect.height), NSColor(white: 0.66, alpha: 1))
        fill(NSRect(x: rect.minX, y: rect.maxY - 1, width: rect.width, height: 1), NSColor(white: 0.06, alpha: 1))
        fill(NSRect(x: rect.maxX - 1, y: rect.minY, width: 1, height: rect.height), NSColor(white: 0.06, alpha: 1))
    }
    private func bevel(_ rect: NSRect, down: Bool) { fill(rect, NSColor(white: down ? 0.46 : 0.69, alpha: 1)); frame(rect) }
    private func text(_ string: String, at point: NSPoint, size: CGFloat, color: NSColor, width: CGFloat = 1000) {
        let style = NSMutableParagraphStyle(); style.lineBreakMode = .byTruncatingTail
        (string as NSString).draw(in: NSRect(x: point.x, y: point.y, width: width, height: size + 5), withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: size, weight: .medium), .foregroundColor: color, .paragraphStyle: style])
    }
    private func transportIcon(_ index: Int, in rect: NSRect, down: Bool) {
        NSColor(white: 0.10, alpha: 1).setFill()
        let x: CGFloat = down ? 9 : 8
        let y: CGFloat = down ? 6 : 5
        if index == 2 { NSRect(x: x - 1, y: y, width: 3, height: 8).fill(); NSRect(x: x + 4, y: y, width: 3, height: 8).fill() }
        else if index == 3 { NSRect(x: x - 1, y: y, width: 8, height: 8).fill() }
        else {
            let path = NSBezierPath()
            if index == 0 { path.move(to: NSPoint(x: x + 6, y: y)); path.line(to: NSPoint(x: x, y: y + 4)); path.line(to: NSPoint(x: x + 6, y: y + 8)); NSRect(x: x - 2, y: y, width: 2, height: 8).fill() }
            else { path.move(to: NSPoint(x: x, y: y)); path.line(to: NSPoint(x: x + 7, y: y + 4)); path.line(to: NSPoint(x: x, y: y + 8)); if index == 4 { NSRect(x: x + 8, y: y, width: 2, height: 8).fill() } }
            path.close(); path.fill()
        }
    }
    /// Winamp's eject glyph: a triangle over a bar, drawn in the same ink as the transport icons.
    private func ejectIcon(in rect: NSRect, down: Bool) {
        NSColor(white: 0.10, alpha: 1).setFill()
        let midX = rect.midX + (down ? 1 : 0), top = rect.minY + (down ? 5 : 4)
        let path = NSBezierPath()
        path.move(to: NSPoint(x: midX, y: top)); path.line(to: NSPoint(x: midX + 5, y: top + 5)); path.line(to: NSPoint(x: midX - 5, y: top + 5)); path.close(); path.fill()
        NSRect(x: midX - 5, y: top + 7, width: 10, height: 2).fill()
    }
    private var miniCycle: DispatchWorkItem?
    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if p.y < 15 {
            if event.clickCount == 2 { action?("shade") }          // Winamp: double-click the title bar to window-shade
            else { (window as? PlayerWindow)?.trackDrag(event, movesDockedWindows: true) }
        }
        else if let visuals, !shaded, VisDraw.miniSlot.contains(p) {
            // A click cycles Bars → Fire → Oscilloscope; a double-click opens the visualization window instead. The cycle waits out the
            // double-click interval so the first click of a double-click doesn't also change the mode.
            miniCycle?.cancel(); miniCycle = nil
            if event.clickCount >= 2 { visuals.showPanel() }
            else {
                let work = DispatchWorkItem { [weak self] in self?.miniCycle = nil; self?.visuals?.cycleMini() }
                miniCycle = work
                DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval, execute: work)
            }
        }
        else if !shaded, event.clickCount == 2, NSRect(x: 111, y: 24, width: 154, height: 12).contains(p) { action?("info") }   // double-click the title display for Station Info
        else if !shaded, NSRect(x: 247, y: 91, width: 20, height: 25).contains(p) { action?("about") }   // the logo at the bottom right, as in Winamp
        else if NSRect(x: 107, y: 57, width: 68, height: 16).contains(p) { trackingVolume = true; adjustVolume(p) }
        else if !shaded, Self.balanceSlot.contains(p) { trackingBalance = true; adjustBalance(p) }
    }
    override func rightMouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let visuals, !shaded, VisDraw.miniSlot.contains(p) { NSMenu.popUpContextMenu(visuals.menu(), with: event, for: self) }
        else { super.rightMouseDown(with: event) }
    }
    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if trackingVolume { adjustVolume(p) } else if trackingBalance { adjustBalance(p) }
    }
    override func mouseUp(with event: NSEvent) { trackingVolume = false; trackingBalance = false }
    private func adjustBalance(_ point: NSPoint) { balanceChanged?(StereoBalance.snapped(Float((point.x - 184) / 12 - 1))) }

    override func scrollWheel(with event: NSEvent) {
        guard !shaded, NSRect(x: 107, y: 57, width: 68, height: 16).contains(convert(event.locationInWindow, from: nil)), event.scrollingDeltaY != 0 else { return super.scrollWheel(with: event) }
        let step = Float(event.scrollingDeltaY) * (event.hasPreciseScrollingDeltas ? 0.004 : 0.03)
        volumeChanged?(min(1, max(0, engine.player.volume + step)))
    }
    private func adjustVolume(_ point: NSPoint) { volumeChanged?(Float(min(1, max(0, (point.x - 114) / 51)))) }
    override func keyDown(with event: NSEvent) {
        if event.characters == " " { action?(engine.status == .playing || engine.status == .connecting ? "pause" : "play") }
        else if let id = ["z": "previous", "x": "play", "c": "pause", "v": "stop", "b": "next"][event.charactersIgnoringModifiers?.lowercased() ?? ""], !event.modifierFlags.contains(.command) { action?(id) }
        else if event.keyCode == 123 { action?("back10") }
        else if event.keyCode == 124 { action?("forward10") }
        else if event.charactersIgnoringModifiers?.lowercased() == "l", !event.modifierFlags.contains(.command) { action?("live") }
        else if event.charactersIgnoringModifiers?.lowercased() == "j", !event.modifierFlags.contains(.command) { action?("jump") }
        else if event.charactersIgnoringModifiers?.lowercased() == "i", !event.modifierFlags.contains(.command) { action?("info") }
        else if event.keyCode == 126 { volumeChanged?(min(1, engine.player.volume + 0.05)) }
        else if event.keyCode == 125 { volumeChanged?(max(0, engine.player.volume - 0.05)) }
        else { super.keyDown(with: event) }
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL], let url = urls.first else { return false }
        action?("skin:\(url.path)"); return true
    }
}
