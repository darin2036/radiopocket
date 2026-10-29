import AppKit

final class EQSlider: NSSlider {
    var skin: ClassicSkin?
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.current?.imageInterpolation = .none
        let frame = Int(((doubleValue + 12) / 24 * 27).rounded())
        if let background = skin?.sprite("eqmain.bmp", NSRect(x: 13 + (frame % 14) * 15, y: 164 + (frame / 14) * 65, width: 14, height: 63)) {
            background.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.none.rawValue])
        } else {
            ClassicUI.panel.setFill(); bounds.fill()
            NSColor.darkGray.setFill(); NSRect(x: 5, y: 0, width: 3, height: 62).fill()
            NSColor.gray.setFill(); NSRect(x: 2, y: 31, width: 10, height: 1).fill()
        }
        let rect = NSRect(x: 1, y: ((12 - doubleValue) / 24 * 51).rounded(), width: 11, height: 11)
        if let image = skin?.sprite("eqmain.bmp", NSRect(x: 0, y: 164, width: 11, height: 11)) {
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.none.rawValue])
        } else {
            NSColor(white: 0.72, alpha: 1).setFill(); rect.fill()
            NSColor(white: 0.93, alpha: 1).setFill(); NSRect(x: rect.minX, y: rect.minY, width: 11, height: 1).fill()
            NSColor(calibratedRed: 0.68, green: 0.96, blue: 0.39, alpha: 1).setFill()
            NSRect(x: rect.minX + 2, y: rect.minY + 5, width: 7, height: 2).fill()
        }
    }
    private func update(_ event: NSEvent) {
        let y = convert(event.locationInWindow, from: nil).y
        doubleValue = max(-12, min(12, 12 - (y - 5.5) / 51 * 24))
        if event.modifierFlags.contains(.option) { doubleValue = 0 }
        needsDisplay = true; sendAction(action, to: target)
    }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if event.clickCount == 2 { doubleValue = 0; needsDisplay = true; sendAction(action, to: target) }
        else { update(event) }
    }
    override func mouseDragged(with event: NSEvent) { update(event) }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 126 || event.keyCode == 125 {
            doubleValue = min(12,max(-12,doubleValue + (event.keyCode == 126 ? 0.5 : -0.5)))
            needsDisplay = true; sendAction(action, to: target)
        } else { super.keyDown(with: event) }
    }
}

final class EqualizerView: NSView {
    let equalizer: Equalizer
    var skin: ClassicSkin? { didSet { sliders.forEach { $0.skin = skin; $0.needsDisplay = true }; refresh() } }
    var shaded = false { didSet {
        sliders.forEach { $0.isHidden = shaded }; buttons.forEach { $0.isHidden = shaded && $0.frame.minY >= 14 }; needsDisplay = true
    } }
    var action: ((String) -> Void)?
    private var sliders: [EQSlider] = []
    private var buttons: [PixelButton] = []
    private let labels = ["PRE", "60", "170", "310", "600", "1K", "3K", "6K", "12K", "14K", "16K"]
    override var isFlipped: Bool { true }
    init(equalizer: Equalizer) {
        self.equalizer = equalizer
        super.init(frame: NSRect(x: 0, y: 0, width: 550, height: 232))
        setBoundsSize(NSSize(width: 275, height: 116))
        for index in 0...10 {
            let x = index == 0 ? 21 : 78 + (index - 1) * 18
            let slider = EQSlider(frame: NSRect(x: x, y: 38, width: 14, height: 63))
            slider.minValue = -12; slider.maxValue = 12
            slider.tag = index
            slider.target = self; slider.action = #selector(slide(_:))
            slider.isContinuous = true
            slider.setAccessibilityLabel(index == 0 ? "Preamp, decibels" : "\(labels[index]) Hz, decibels")
            sliders.append(slider); addSubview(slider)
        }
        addButton("on", "Enable or bypass equalizer", NSRect(x: 14, y: 18, width: 26, height: 12))
        addButton("flat", "Reset to Flat", NSRect(x: 40, y: 18, width: 32, height: 12))
        addButton("presets", "Choose equalizer preset", NSRect(x: 217, y: 18, width: 44, height: 12))
        addButton("shade", "Toggle compact equalizer title bar", NSRect(x: 254, y: 3, width: 9, height: 9))
        addButton("close", "Hide equalizer", NSRect(x: 264, y: 3, width: 9, height: 9))
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }
    private func addButton(_ id: String, _ label: String, _ rect: NSRect) {
        let button = PixelButton(frame: rect)
        button.identifier = .init(id); button.title = ""; button.isBordered = false
        button.setButtonType(.momentaryPushIn); button.setAccessibilityLabel(label); button.toolTip = label
        button.target = self; button.action = #selector(clicked(_:))
        button.paint = { [weak self] rect, down in
            guard let self else { return }
            let source: NSRect?
            switch id {
            case "on": source = NSRect(x: self.equalizer.settings.enabled ? (down ? 187 : 69) : (down ? 128 : 10), y: 119, width: 26, height: 12)
            case "presets": source = NSRect(x: 224, y: down ? 176 : 164, width: 44, height: 12)
            case "shade": source = NSRect(x: 254, y: 137, width: 9, height: 9)
            case "close": source = NSRect(x: 0, y: down ? 125 : 116, width: 9, height: 9)
            default: source = nil
            }
            if let source, self.sprite(source, target: rect) { return }
            ClassicUI.bevel(rect, down: down)
            ClassicUI.caption(id == "on" ? (self.equalizer.settings.enabled ? "ON" : "OFF") : (id == "flat" ? "FLAT" : id == "close" ? "×" : "PRESETS"), rect: rect, font: .monospacedSystemFont(ofSize: 6, weight: .medium))
        }
        buttons.append(button); addSubview(button)
    }
    @objc private func clicked(_ button: NSButton) {
        switch button.identifier!.rawValue {
        case "on": equalizer.settings.enabled.toggle()
        case "flat": equalizer.select(EQPreset.classic.first { $0.name == "Flat" }!)
        case "presets": presetMenu()
        case "shade": action?("shade")
        default: window?.orderOut(nil)
        }
    }
    @objc private func slide(_ slider: NSSlider) {
        var settings = equalizer.settings
        if slider.tag == 0 { settings.preamp = slider.floatValue } else { settings.bands[slider.tag - 1] = slider.floatValue }
        settings.preset = "Custom"
        equalizer.settings = settings
    }
    func refresh() {
        for (i, slider) in sliders.enumerated() {
            slider.floatValue = i == 0 ? equalizer.settings.preamp : equalizer.settings.bands[i - 1]
            slider.toolTip = "\(labels[i]): \(String(format: "%+.1f", slider.floatValue)) dB • Double-click to reset"
            slider.needsDisplay = true
        }
        buttons.forEach { $0.needsDisplay = true }; needsDisplay = true
    }
    private func presetMenu() {
        let menu = NSMenu()
        for (i, preset) in (EQPreset.classic + equalizer.settings.custom).enumerated() {
            if i == EQPreset.classic.count { menu.addItem(.separator()) }
            let item = NSMenuItem(title: preset.name, action: #selector(selectPreset(_:)), keyEquivalent: "")
            item.tag = i; item.target = self; item.state = equalizer.settings.preset == preset.name ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        for (title, id) in [("Save Current Preset…", "save"), ("Import Winamp EQF…", "import"), ("Export Current EQF…", "export")] {
            let item = NSMenuItem(title: title, action: #selector(presetAction(_:)), keyEquivalent: "")
            item.representedObject = id; item.target = self; menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 217, y: 31), in: self)
    }
    @objc private func selectPreset(_ sender: NSMenuItem) { equalizer.select((EQPreset.classic + equalizer.settings.custom)[sender.tag]) }
    @objc private func presetAction(_ sender: NSMenuItem) { action?(sender.representedObject as! String) }
    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.current?.imageInterpolation = .none
        NSColor(calibratedRed: 0.19, green: 0.20, blue: 0.25, alpha: 1).setFill(); bounds.fill()
        if !sprite(NSRect(x: 0, y: 0, width: 275, height: 116), target: NSRect(x: 0, y: 0, width: 275, height: 116)) {
            NSColor(white: 0.5, alpha: 1).setFill(); NSRect(x: 3, y: 3, width: 269, height: 1).fill()
            text("R A D I O P O C K E T   E Q", x: 72, y: 4, size: 6, color: .lightGray)
            for (i, label) in labels.enumerated() { text(label, x: i == 0 ? 19 : 77 + CGFloat(i - 1)*18, y: 102, size: 5, color: .lightGray) }
            text("+12", x: 42, y: 38, size: 6, color: .lightGray)
            text("0 dB", x: 42, y: 64, size: 6, color: .lightGray)
            text("−12", x: 42, y: 91, size: 6, color: .lightGray)
        } else { _ = sprite(NSRect(x: 0, y: 134, width: 275, height: 14), target: NSRect(x: 0, y: 0, width: 275, height: 14)) }
        if shaded { return }
        let graph = NSRect(x: 86, y: 17, width: 113, height: 19)
        if !sprite(NSRect(x: 0, y: 294, width: 113, height: 19), target: graph) {
            ClassicUI.black.setFill(); graph.fill()
        }
        NSGraphicsContext.saveGraphicsState(); graph.clip()
        ClassicUI.green.setStroke()
        let curve = NSBezierPath(); curve.lineWidth = 0.7
        for (i, gain) in equalizer.settings.bands.enumerated() {
            let point = NSPoint(x: graph.minX + CGFloat(i) * 12.4, y: graph.midY - CGFloat(gain) * 0.65)
            if i == 0 { curve.move(to: point) } else { curve.line(to: point) }
        }
        curve.stroke(); NSGraphicsContext.restoreGraphicsState()
        toolTip = "Preset: \(equalizer.settings.preset) • Curve shows band gains"

    }
    private func sprite(_ source: NSRect, target: NSRect) -> Bool {
        guard let image = skin?.sprite("eqmain.bmp", source) else { return false }
        image.draw(in: target, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.none.rawValue]); return true
    }
    private func text(_ string: String, x: CGFloat, y: CGFloat, size: CGFloat, color: NSColor, width: CGFloat = 200) {
        let style = NSMutableParagraphStyle(); style.lineBreakMode = .byTruncatingTail
        (string as NSString).draw(in: NSRect(x: x, y: y, width: width, height: 12), withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: size, weight: .medium), .foregroundColor: color, .paragraphStyle: style])
    }
    override func mouseDown(with event: NSEvent) {
        guard convert(event.locationInWindow, from: nil).y < 14 else { return }
        if event.clickCount == 2 { action?("shade") } else { (window as? PlayerWindow)?.trackDrag(event) }
    }
}
