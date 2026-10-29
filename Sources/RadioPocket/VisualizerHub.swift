import AppKit

extension NSColor {
    convenience init(rgb: VisColors.RGB) { self.init(srgbRed: CGFloat(rgb.r) / 255, green: CGFloat(rgb.g) / 255, blue: CGFloat(rgb.b) / 255, alpha: 1) }
}

/// Owns the analyzer and one display timer. The timer exists only while a registered view is actually
/// visible and either audio is playing or the bars are still falling to zero; otherwise nothing polls.
final class VisualizerHub {
    struct Client {
        weak var owner: AnyObject?
        let fullRate: () -> Bool
        let visible: () -> Bool
        let redraw: () -> Void
        let busy: () -> Bool
    }
    let analyzer = SpectrumAnalyzer()
    let miniFire = FireField()
    var settings = VisSettings() { didSet {
        guard settings != oldValue else { return }
        settingObservers.forEach { $0(settings) }
        refresh()
    } }
    /// Fills `count` samples and returns the sample rate, or nil when no audio is available.
    var source: ((UnsafeMutablePointer<Float>, Int) -> Double?)?
    /// True while the current stream is playing and can supply samples.
    var hasSignal: () -> Bool = { false }
    var frame: VisFrame { analyzer.frame }

    private var clients: [Client] = []
    private var settingObservers: [(VisSettings) -> Void] = []
    private var timer: Timer?
    private var interval = 0.0
    private var lastTick = CACurrentMediaTime()
    private var lastCycle = CACurrentMediaTime()
    private var samples = [Float](repeating: 0, count: SpectrumAnalyzer.size)
    private var observers: [NSObjectProtocol] = []
    private var cachedSkin: ClassicSkin?
    private var cachedColors = VisColors.standard.map(NSColor.init(rgb:))
    var isRunning: Bool { timer != nil }

    /// Winamp’s 24-entry palette from the current skin’s VISCOLOR.TXT (stock colours when absent).
    var colors: [NSColor] {
        let skin = ClassicUI.skin
        if skin !== cachedSkin { cachedSkin = skin; cachedColors = (skin?.visColors ?? VisColors.standard).map(NSColor.init(rgb:)) }
        return cachedColors
    }

    init() {
        let center = NotificationCenter.default
        for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
                     NSWindow.willCloseNotification, NSApplication.didHideNotification, NSApplication.didUnhideNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.refresh() })
        }
    }
    deinit { observers.forEach(NotificationCenter.default.removeObserver); timer?.invalidate() }

    static func windowVisible(_ window: NSWindow?) -> Bool {
        guard let window else { return false }
        return window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible) && !NSApp.isHidden
    }

    func register(owner: AnyObject, fullRate: @escaping () -> Bool = { false }, visible: @escaping () -> Bool, redraw: @escaping () -> Void, busy: @escaping () -> Bool = { false }) {
        clients.append(Client(owner: owner, fullRate: fullRate, visible: visible, redraw: redraw, busy: busy))
    }
    func observeSettings(_ block: @escaping (VisSettings) -> Void) { settingObservers.append(block) }

    /// Re-evaluates whether the timer should run. Call after playback, window visibility or settings change.
    func refresh() {
        clients.removeAll { $0.owner == nil }
        let visible = clients.filter { $0.visible() }
        guard !visible.isEmpty, hasSignal() || !analyzer.isSilent || animating(visible) else {
            stop()
            visible.forEach { $0.redraw() }
            return
        }
        let fps = visible.contains { $0.fullRate() } ? 60 : settings.refresh.framesPerSecond
        if timer == nil || abs(interval - 1 / fps) > 0.0001 {
            timer?.invalidate()
            interval = 1 / fps
            lastTick = CACurrentMediaTime()
            let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.tick() }
            timer.tolerance = interval * 0.1
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
    }

    /// Developer previews only: pushes a synthetic frame through the same smoothing as live audio.
    func injectDemoFrame(phase: Float) {
        let raw = (0..<SpectrumAnalyzer.bands).map { i -> Float in
            let x = Float(i) / Float(SpectrumAnalyzer.bands)
            return min(1, max(0.02, 0.85 - x * 0.55 + 0.22 * sin(x * 19 + phase) * sin(phase * 0.7 + x * 5) + 0.1 * sin(x * 61 + phase * 2)))
        }
        let scope = (0..<SpectrumAnalyzer.scopeLength).map { 0.22 * sin(Float($0) * 0.11 + phase) + 0.1 * sin(Float($0) * 0.43) }
        analyzer.advance(raw: raw, scope: scope, dt: 0.2, falloff: 4)
    }

    /// Flames keep burning down after the bars hit zero.
    private func animating(_ visible: [Client]) -> Bool { miniFire.isHot || visible.contains { $0.busy() } }

    private func stop() { timer?.invalidate(); timer = nil }

    private func tick() {
        let visible = clients.filter { $0.owner != nil && $0.visible() }
        guard !visible.isEmpty else { stop(); return }
        let now = CACurrentMediaTime()
        let dt = min(0.25, now - lastTick)
        lastTick = now
        var rate: Double?
        if hasSignal() { rate = samples.withUnsafeMutableBufferPointer { source?($0.baseAddress!, $0.count) } }
        if let rate {
            analyzer.advance(raw: analyzer.bands(from: samples, sampleRate: rate), scope: SpectrumAnalyzer.scopeWindow(from: samples), dt: dt, falloff: settings.falloff, peakFalloff: settings.peakFalloff)
        } else {
            analyzer.decay(dt: dt, falloff: settings.falloff, peakFalloff: settings.peakFalloff)
        }
        if settings.mini == .fire { miniFire.resize(columns: 76, rows: 16); miniFire.advance(dt: dt, bars: analyzer.frame.bars, settings: settings) }
        if settings.autoCycle, now - lastCycle > 15 { lastCycle = now; settings.panel = settings.panel.next }
        visible.forEach { $0.redraw() }
        if rate == nil, analyzer.isSilent, !animating(visible) { stop() }
    }
}
