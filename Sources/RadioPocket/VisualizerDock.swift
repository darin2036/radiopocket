import AppKit

/// Draws the window visualization into the Dock icon while audio plays, and hands the icon back when it stops.
/// The Dock redraws through another process, so the tile is throttled to 15 fps whatever the hub's rate is.
final class DockTileVisualizer: NSView {
    private static let interval = 1.0 / 15
    private let hub: VisualizerHub
    private let state = VisState()
    private var history: [[Float]] = []
    private var lastDraw = 0.0
    private var installed = false

    private var active: Bool { hub.settings.dockIcon && (hub.hasSignal() || !hub.analyzer.isSilent) }

    init(hub: VisualizerHub) {
        self.hub = hub
        super.init(frame: NSRect(x: 0, y: 0, width: 128, height: 128))
        hub.register(owner: self, visible: { [unowned self] in self.active }, redraw: { [unowned self] in self.tick() })
        hub.observeSettings { [weak self] _ in self?.tick() }
        hub.onStop.append { [weak self] in self?.restore() }
    }
    required init?(coder: NSCoder) { fatalError() }

    private func tick() {
        guard active else { restore(); return }
        let now = CACurrentMediaTime()
        guard now - lastDraw >= Self.interval else { return }
        state.update(hub.frame, dt: now - lastDraw, aspect: 1, mode: hub.settings.panel, settings: hub.settings)
        lastDraw = now
        if hub.settings.panel == .spectrogram || hub.settings.panel == .waterfall {
            history.append(hub.frame.bars)
            if history.count > SpectrogramLimit.columns { history.removeFirst(history.count - SpectrogramLimit.columns) }
        }
        if !installed { installed = true; NSApp.dockTile.contentView = self }
        NSApp.dockTile.display()
    }

    private func restore() {
        guard installed else { return }
        installed = false
        NSApp.dockTile.contentView = nil
        NSApp.dockTile.display()
    }

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.saveGraphicsState(); defer { NSGraphicsContext.restoreGraphicsState() }
        let tile = bounds.insetBy(dx: 8, dy: 8)
        NSBezierPath(roundedRect: tile, xRadius: 26, yRadius: 26).addClip()
        VisDraw.panel(hub.settings.panel, hub: hub, in: tile, history: history, state: state)
    }
}
