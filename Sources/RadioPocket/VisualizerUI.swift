import AppKit

/// Every hotkey the visualization window and full-screen mode accept. Shown in the on-screen help.
enum VisualizerKeys {
    static let help: [(String, String)] = [
        ("Double-click · F · ⌥↩", "Toggle full screen (Esc leaves)"),
        ("Space · → · N", "Next visualization"),
        ("Backspace · ← ", "Previous visualization"),
        ("1 – 9 · 0", "Jump to one of the first ten visualizations"),
        ("R", "Auto-cycle every 15 seconds"),
        ("K", "Cycle colors: Normal / Fire / Line"),
        ("P", "Show / hide peak markers"),
        ("- · =", "Slower / faster falloff"),
        ("T", "Show / hide title overlay"),
        ("Z X C V B", "Previous · Play · Pause · Stop · Next"),
        ("[ · ] · L", "Back 10 s · Forward 10 s · Jump to live"),
        ("↑ ↓", "Volume"),
        ("H · F1", "This help"),
    ]
}

/// What the visualizer should say when there is nothing to draw.
enum VisSignal { case playing, idle, unavailable }

/// The canvas used by both the visualization window and full-screen mode.
final class VisCanvasView: NSView {
    let hub: VisualizerHub
    let fullscreen: Bool
    var perform: ((String) -> Void)?
    var nowPlaying: () -> (station: String, title: String, signal: VisSignal) = { ("", "", .idle) }
    private var history: [[Float]] = []
    private let state = VisState()
    private var lastTick = CACurrentMediaTime()
    private var lastActivity = Date()
    private var lastTitle = ""
    private var showHelp = false
    private var banner: (text: String, until: Date)?
    private var lastPanel: VisPanelMode

    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { true }

    init(hub: VisualizerHub, fullscreen: Bool) {
        self.hub = hub; self.fullscreen = fullscreen; lastPanel = hub.settings.panel
        super.init(frame: .zero)
        hub.register(owner: self, fullRate: { [unowned self] in self.fullscreen }, visible: { [unowned self] in VisualizerHub.windowVisible(self.window) }, redraw: { [unowned self] in self.tick() }, busy: { [unowned self] in self.hub.settings.panel == .fire && self.state.fire.isHot })
        hub.observeSettings { [weak self] settings in
            guard let self else { return }
            if settings.panel != self.lastPanel { self.lastPanel = settings.panel; self.show(settings.panel.title) }
            self.needsDisplay = true
        }
        setAccessibilityRole(.image); setAccessibilityLabel("Audio visualization")
    }
    required init?(coder: NSCoder) { fatalError() }

    private func tick(dt fixed: Double? = nil) {
        let now = CACurrentMediaTime()
        state.update(hub.frame, dt: fixed ?? now - lastTick, aspect: max(0.1, bounds.width / max(1, bounds.height)), mode: hub.settings.panel, settings: hub.settings)
        lastTick = now
        if hub.settings.panel == .spectrogram || hub.settings.panel == .waterfall {
            history.append(hub.frame.bars)
            if history.count > SpectrogramLimit.columns { history.removeFirst(history.count - SpectrogramLimit.columns) }
        }
        if fullscreen, Date().timeIntervalSince(lastActivity) > 3 { NSCursor.setHiddenUntilMouseMoves(true) }
        needsDisplay = true
    }

    private func show(_ text: String) {
        banner = (text, Date().addingTimeInterval(2.5)); bump()
    }
    private func bump() {
        lastActivity = Date(); needsDisplay = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.2) { [weak self] in self?.needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        let (station, title, signal) = nowPlaying()
        if title != lastTitle { lastTitle = title; lastActivity = Date() }
        VisDraw.panel(hub.settings.panel, hub: hub, in: bounds, history: history, state: state)
        let active = Date().timeIntervalSince(lastActivity) < 5
        let big: CGFloat = fullscreen ? max(18, bounds.height / 34) : 13
        if signal != .playing {
            let message = signal == .unavailable ? "Visualization isn’t available for this stream (macOS fallback decoder)" : "Nothing playing — tune in a station"
            text(message, at: NSPoint(x: bounds.midX, y: bounds.midY), size: min(big, bounds.width * 0.9 / (CGFloat(message.count) * 0.62)), color: hub.colors[22], centered: true)
        }
        if fullscreen, hub.settings.overlay, active || signal != .playing {
            if !station.isEmpty { text(station, at: NSPoint(x: big * 1.5, y: big * 3.2), size: big * 1.3, color: hub.colors[18], bold: true) }
            if !title.isEmpty, title != station { text(title, at: NSPoint(x: big * 1.5, y: big * 1.6), size: big, color: hub.colors[20]) }
        }
        if let banner, banner.until > Date() { text(banner.text.uppercased(), at: NSPoint(x: big * 1.5, y: bounds.height - big * 2.4), size: big * 0.9, color: hub.colors[18], bold: true) }
        if showHelp { drawHelp(size: big * 0.85) }
    }

    private func text(_ string: String, at point: NSPoint, size: CGFloat, color: NSColor, bold: Bool = false, centered: Bool = false) {
        let shadow = NSShadow(); shadow.shadowColor = .black; shadow.shadowBlurRadius = 4; shadow.shadowOffset = NSSize(width: 1, height: -1)
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: size, weight: bold ? .bold : .regular), .foregroundColor: color, .shadow: shadow]
        let measured = (string as NSString).size(withAttributes: attributes)
        (string as NSString).draw(at: NSPoint(x: centered ? point.x - measured.width / 2 : point.x, y: point.y), withAttributes: attributes)
    }

    private func drawHelp(size: CGFloat) {
        let lineHeight = size * 1.7, width = size * 44, height = lineHeight * CGFloat(VisualizerKeys.help.count + 2)
        let box = NSRect(x: bounds.midX - width / 2, y: bounds.midY - height / 2, width: width, height: height)
        NSColor.black.withAlphaComponent(0.82).setFill(); NSBezierPath(roundedRect: box, xRadius: 8, yRadius: 8).fill()
        text("VISUALIZATION KEYS", at: NSPoint(x: box.minX + size, y: box.maxY - lineHeight * 1.3), size: size, color: hub.colors[18], bold: true)
        for (index, line) in VisualizerKeys.help.enumerated() {
            let y = box.maxY - lineHeight * (CGFloat(index) + 2.3)
            text(line.0, at: NSPoint(x: box.minX + size, y: y), size: size, color: hub.colors[18], bold: true)
            text(line.1, at: NSPoint(x: box.minX + size * 16, y: y), size: size, color: hub.colors[21])
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self); bump()
        if event.clickCount == 2 { perform?("vis:fullscreen") }
    }
    override func mouseMoved(with event: NSEvent) { bump() }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        if fullscreen { addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self)) }
    }

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) { super.keyDown(with: event); return }
        bump()
        if event.keyCode == 36, event.modifierFlags.contains(.option) { perform?("vis:fullscreen"); return }
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let routes: [UInt16: String] = [53: "vis:exitfull", 123: "vis:prevmode", 124: "vis:nextmode", 51: "vis:prevmode", 126: "volumeUp", 125: "volumeDown"]
        let letters = ["f": "vis:fullscreen", " ": "vis:nextmode", "n": "vis:nextmode", "r": "vis:autocycle", "k": "vis:colornext", "p": "vis:peaks", "t": "vis:overlay",
                       "-": "vis:falloffdown", "=": "vis:falloffup", "+": "vis:falloffup",
                       "z": "previous", "x": "play", "c": "pause", "v": "stop", "b": "next", "l": "live", "[": "back10", "]": "forward10"]
        if event.keyCode == 122 || key == "h" { showHelp.toggle(); needsDisplay = true }
        else if let id = routes[event.keyCode] ?? letters[key] { perform?(id) }
        else if let number = Int(key), case let index = (number + 9) % 10, index < VisPanelMode.allCases.count { perform?("vis:mode:\(VisPanelMode.allCases[index].rawValue)") }
        else { super.keyDown(with: event) }
    }

    /// Developer previews: renders every window visualization from synthetic data.
    func exportPreviews(into directory: URL) {
        frame = NSRect(x: 0, y: 0, width: 960, height: 540)
        let original = hub.settings.panel
        for mode in VisPanelMode.allCases {
            hub.settings.panel = mode
            history.removeAll()
            for step in 0..<90 { hub.injectDemoFrame(phase: Float(step) * 0.25); tick(dt: 1.0 / 30) }
            exportPreview(directory.appendingPathComponent("RadioPocket-vis-\(mode.rawValue).png"))
        }
        hub.settings.panel = original
    }

    func exportPreview(_ url: URL) {
        needsDisplay = true
        if let rep = bitmapImageRepForCachingDisplay(in: bounds) {
            cacheDisplay(in: bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
        }
    }
}

private final class FullscreenWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// The classic-styled visualization window: mode picker and peaks toggle around a resizable canvas.
final class VisPanelController: NSObject {
    let window: PlayerWindow
    let canvas: VisCanvasView
    private let modes = ClassicPopup(frame: .zero, pullsDown: false)
    private let peaks = ClassicCheckBox(title: "Peaks", target: nil, action: nil)
    private let full: ClassicButton
    private let hub: VisualizerHub
    var perform: ((String) -> Void)? { didSet { canvas.perform = perform } }

    init(hub: VisualizerHub) {
        self.hub = hub
        canvas = VisCanvasView(hub: hub, fullscreen: false)
        let size = NSSize(width: 720, height: 460)
        window = PlayerWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        full = ClassicButton(title: "FULL SCREEN", target: nil, action: nil)
        super.init()
        window.isReleasedWhenClosed = false; window.hasShadow = true; window.appearance = NSAppearance(named: .darkAqua); window.isUserResizable = true
        window.title = "RadioPocket Visualization"; window.minSize = NSSize(width: 275, height: 200)
        window.setFrameAutosaveName("RadioPocket.Visualization")
        let root = ClassicChrome(frame: NSRect(origin: .zero, size: size)); root.title = "VISUALIZATION"; window.contentView = root
        let close = ClassicWindowButton(title: "×", target: self, action: #selector(closeWindow))
        close.frame = NSRect(x: size.width - 12, y: 3, width: 9, height: 9); close.isBordered = false; close.autoresizingMask = [.minXMargin]
        close.setAccessibilityLabel("Close visualization"); root.addSubview(close)

        modes.frame = NSRect(x: 14, y: 22, width: 170, height: 20); modes.isBordered = false
        modes.addItems(withTitles: VisPanelMode.allCases.map(\.title)); modes.target = self; modes.action = #selector(modeChanged); modes.setAccessibilityLabel("Visualization")
        peaks.frame = NSRect(x: 192, y: 22, width: 70, height: 20); peaks.setButtonType(.switch); peaks.isBordered = false; peaks.font = ClassicUI.font
        peaks.target = self; peaks.action = #selector(peaksChanged)
        full.target = self; full.action = #selector(fullScreen); full.isBordered = false
        full.setAccessibilityLabel("Full screen visualization")
        [modes, peaks, full].forEach(root.addSubview)

        canvas.frame = NSRect(x: 12, y: 48, width: size.width - 24, height: size.height - 48 - 16)
        canvas.autoresizingMask = [.width, .height]
        root.addSubview(canvas)
        hub.observeSettings { [weak self] _ in self?.sync() }
        NotificationCenter.default.addObserver(self, selector: #selector(layoutControls), name: NSWindow.didResizeNotification, object: window)
        layoutControls(); sync()
    }

    /// Below 480 pt (down to the player's 275 pt) the peaks control gives way to a wider mode picker; its key (P) and the Visualization menu still work.
    @objc private func layoutControls() {
        guard let width = window.contentView?.bounds.width else { return }
        let wide = width >= 480
        peaks.isHidden = !wide
        full.title = wide ? "FULL SCREEN" : "FULL"
        let fullWidth: CGFloat = wide ? 108 : 48
        full.frame = NSRect(x: width - fullWidth - 16, y: 22, width: fullWidth, height: 20)
        modes.frame = NSRect(x: 14, y: 22, width: wide ? 170 : max(80, width - fullWidth - 16 - 14 - 8), height: 20)
        [modes, full].forEach { $0.needsDisplay = true }
    }

    private func sync() {
        modes.selectItem(at: VisPanelMode.allCases.firstIndex(of: hub.settings.panel) ?? 0)
        peaks.state = hub.settings.peaks ? .on : .off
        [modes, peaks].forEach { $0.needsDisplay = true }
    }
    func show() {
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(canvas)
        hub.refresh()
    }
    @objc private func closeWindow() { window.orderOut(nil); hub.refresh() }
    @objc private func modeChanged() { hub.settings.panel = VisPanelMode.allCases[modes.indexOfSelectedItem] }
    @objc private func peaksChanged() { hub.settings.peaks = peaks.state == .on }
    @objc private func fullScreen() { perform?("vis:fullscreen") }
}

/// Glue between the app and everything visual: owns the hub, panel and full-screen window, builds menus, routes hotkeys.
final class VisualizerController: NSObject, NSMenuItemValidation {
    let hub = VisualizerHub()
    /// Transport and volume ids (previous, play, pause, stop, next, volumeUp, volumeDown) go back to the app.
    var perform: ((String) -> Void)?
    var nowPlaying: () -> (station: String, title: String, signal: VisSignal) = { ("", "", .idle) }
    weak var playerWindow: NSWindow?
    private lazy var panel: VisPanelController = {
        let panel = VisPanelController(hub: hub)
        panel.canvas.nowPlaying = { [unowned self] in self.nowPlaying() }
        panel.perform = { [unowned self] in self.handle($0) }
        return panel
    }()
    private var fullscreenWindow: NSWindow?
    private var returnWindow: NSWindow?

    var isFullscreen: Bool { fullscreenWindow != nil }

    func showPanel() { panel.show() }
    /// Developer previews: the visualization window’s chrome and controls, drawn with the current demo frame.
    func exportPanelPreview(_ url: URL) {
        guard let content = panel.window.contentView else { return }
        content.layoutSubtreeIfNeeded()
        if let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
            content.cacheDisplay(in: content.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
        }
    }
    func cycleMini() { hub.settings.mini = hub.settings.mini.next }

    func toggleFullscreen() {
        if fullscreenWindow != nil { exitFullscreen(); return }
        let screen = (NSApp.keyWindow ?? playerWindow)?.screen ?? NSScreen.main ?? NSScreen.screens[0]
        returnWindow = NSApp.keyWindow
        let canvas = VisCanvasView(hub: hub, fullscreen: true)
        canvas.nowPlaying = { [unowned self] in self.nowPlaying() }
        canvas.perform = { [unowned self] in self.handle($0) }
        let window = FullscreenWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.backgroundColor = .black; window.hasShadow = false; window.acceptsMouseMovedEvents = true
        window.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        window.title = "RadioPocket Visualization"
        window.contentView = canvas
        NSApp.presentationOptions = [.hideDock, .hideMenuBar]
        window.setFrame(screen.frame, display: true)
        window.makeKeyAndOrderFront(nil); window.makeFirstResponder(canvas)
        NSApp.activate(ignoringOtherApps: true)
        fullscreenWindow = window
        hub.refresh()
    }
    private func exitFullscreen() {
        guard let window = fullscreenWindow else { return }
        fullscreenWindow = nil
        NSApp.presentationOptions = []
        NSCursor.unhide()
        window.orderOut(nil); window.contentView = nil
        (returnWindow ?? playerWindow)?.makeKeyAndOrderFront(nil)
        returnWindow = nil
        hub.refresh()
    }

    func handle(_ id: String) {
        guard id.hasPrefix("vis:") else { perform?(id); return }
        let parts = id.split(separator: ":").map(String.init)
        var s = hub.settings
        switch parts[1] {
        case "panel": showPanel(); return
        case "fullscreen": toggleFullscreen(); return
        case "exitfull": exitFullscreen(); return
        case "mini": s.mini = MiniVisMode(rawValue: parts[2]) ?? s.mini
        case "mode": s.panel = VisPanelMode(rawValue: parts[2]) ?? s.panel
        case "nextmode": s.panel = s.panel.next
        case "prevmode": s.panel = s.panel.previous
        case "color": s.coloring = VisColoring(rawValue: parts[2]) ?? s.coloring
        case "colornext": s.coloring = s.coloring.next
        case "peaks": s.peaks.toggle()
        case "falloff": s.falloff = min(4, max(0, Int(parts[2]) ?? s.falloff))
        case "falloffup": s.falloff = min(4, s.falloff + 1)
        case "falloffdown": s.falloff = max(0, s.falloff - 1)
        case "peakfall": s.peakFalloff = min(4, max(0, Int(parts[2]) ?? s.peakFalloff))
        case "bandwidth": s.bandWidth = BandWidth(rawValue: parts[2]) ?? s.bandWidth
        case "fireheight": s.fireHeight = min(4, max(0, Int(parts[2]) ?? s.fireHeight))
        case "fireturb": s.fireTurbulence = min(4, max(0, Int(parts[2]) ?? s.fireTurbulence))
        case "firepalette": s.firePalette = FirePalette(rawValue: parts[2]) ?? s.firePalette
        case "prefs": perform?("visprefs"); return
        case "scope": s.scope = ScopeStyle(rawValue: parts[2]) ?? s.scope
        case "refresh": s.refresh = VisRefresh(rawValue: parts[2]) ?? s.refresh
        case "autocycle": s.autoCycle.toggle()
        case "overlay": s.overlay.toggle()
        default: return
        }
        hub.settings = s
    }

    // MARK: Menus

    /// A fresh menu each call (a menu item can only live in one menu). Key equivalents are for the menu bar only.
    func menu(withKeys: Bool = false) -> NSMenu {
        let menu = NSMenu(title: "Visualization")
        func item(_ title: String, _ id: String, key: String = "", modifiers: NSEvent.ModifierFlags = [.command], into target: NSMenu? = nil) {
            let entry = NSMenuItem(title: title, action: #selector(menuAction(_:)), keyEquivalent: withKeys ? key : "")
            entry.keyEquivalentModifierMask = modifiers; entry.target = self; entry.representedObject = id
            (target ?? menu).addItem(entry)
        }
        func submenu(_ title: String, _ items: [(String, String)]) {
            let root = NSMenuItem(title: title, action: nil, keyEquivalent: ""); let sub = NSMenu(title: title); root.submenu = sub; menu.addItem(root)
            for (name, id) in items { item(name, id, into: sub) }
        }
        item("Visualization Window", "vis:panel", key: "v", modifiers: [.command, .shift])
        item("Full Screen Visualization", "vis:fullscreen", key: "f", modifiers: [.command, .control])
        menu.addItem(.separator())
        submenu("Player Visualizer", MiniVisMode.allCases.map { ($0.title, "vis:mini:\($0.rawValue)") })
        submenu("Window Visualization", VisPanelMode.allCases.map { ($0.title, "vis:mode:\($0.rawValue)") })
        submenu("Coloring", VisColoring.allCases.map { ($0.title, "vis:color:\($0.rawValue)") })
        submenu("Analyzer Falloff", ["Slower", "Slow", "Moderate", "Fast", "Faster"].enumerated().map { ($1, "vis:falloff:\($0)") })
        let levels = ["Lowest", "Low", "Medium", "High", "Highest"]
        submenu("Peak Falloff", ["Slower", "Slow", "Moderate", "Fast", "Faster"].enumerated().map { ($1, "vis:peakfall:\($0)") })
        submenu("Band Line Width", BandWidth.allCases.map { ($0.title, "vis:bandwidth:\($0.rawValue)") })
        submenu("Fire Height", levels.enumerated().map { ($1, "vis:fireheight:\($0)") })
        submenu("Fire Turbulence", ["Calm", "Gentle", "Medium", "Strong", "Wild"].enumerated().map { ($1, "vis:fireturb:\($0)") })
        submenu("Fire Colors", FirePalette.allCases.map { ($0.title, "vis:firepalette:\($0.rawValue)") })
        submenu("Oscilloscope Style", ScopeStyle.allCases.map { ($0.title, "vis:scope:\($0.rawValue)") })
        submenu("Refresh Rate", VisRefresh.allCases.map { ($0.title, "vis:refresh:\($0.rawValue)") })
        menu.addItem(.separator())
        item("Visualization Settings…", "vis:prefs")
        menu.addItem(.separator())
        item("Show Peaks", "vis:peaks"); item("Auto-Cycle Visualizations", "vis:autocycle"); item("Show Title in Full Screen", "vis:overlay")
        return menu
    }
    @objc private func menuAction(_ sender: NSMenuItem) { if let id = sender.representedObject as? String { handle(id) } }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard let id = item.representedObject as? String, id.hasPrefix("vis:") else { return true }
        let s = hub.settings, parts = id.split(separator: ":").map(String.init)
        let checked: Bool?
        switch parts[1] {
        case "mini": checked = s.mini.rawValue == parts[2]
        case "mode": checked = s.panel.rawValue == parts[2]
        case "color": checked = s.coloring.rawValue == parts[2]
        case "falloff": checked = s.falloff == Int(parts[2])
        case "peakfall": checked = s.peakFalloff == Int(parts[2])
        case "bandwidth": checked = s.bandWidth.rawValue == parts[2]
        case "fireheight": checked = s.fireHeight == Int(parts[2])
        case "fireturb": checked = s.fireTurbulence == Int(parts[2])
        case "firepalette": checked = s.firePalette.rawValue == parts[2]
        case "scope": checked = s.scope.rawValue == parts[2]
        case "refresh": checked = s.refresh.rawValue == parts[2]
        case "peaks": checked = s.peaks
        case "autocycle": checked = s.autoCycle
        case "overlay": checked = s.overlay
        case "fullscreen": checked = isFullscreen
        default: checked = nil
        }
        item.state = checked == true ? .on : .off
        return true
    }
}
