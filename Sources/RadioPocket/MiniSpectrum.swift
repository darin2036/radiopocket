import AppKit

/// A small live spectrum for a shaded bar, drawn from the shared visualizer hub in the skin's visualizer colours.
final class MiniSpectrum: NSView {
    private weak var hub: VisualizerHub?
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    func attach(to hub: VisualizerHub) {
        self.hub = hub
        hub.register(owner: self, visible: { [weak self] in
            guard let self, !self.isHiddenOrHasHiddenAncestor else { return false }
            return VisualizerHub.windowVisible(self.window)
        }, redraw: { [weak self] in self?.needsDisplay = true })
    }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); hub?.refresh() }
    override func viewDidHide() { super.viewDidHide(); hub?.refresh() }
    override func viewDidUnhide() { super.viewDidUnhide(); hub?.refresh() }
    override func draw(_ dirtyRect: NSRect) {
        let colors = hub?.colors ?? []
        (colors.first ?? ClassicUI.black).setFill(); bounds.fill()
        guard let hub, colors.count > 23, hub.hasSignal() else { return }
        let bars = hub.frame.bars, count = Int((bounds.width + 1) / 4), per = max(1, bars.count / count)
        for bar in 0..<count {
            let range = (bar * per)..<min(bars.count, (bar + 1) * per)
            let level = range.compactMap { bars.indices.contains($0) ? bars[$0] : nil }.max() ?? 0
            let height = Int((CGFloat(level) * bounds.height).rounded())
            for row in 0..<height {
                colors[17 - min(15, row * 15 / max(1, Int(bounds.height) - 1))].setFill()
                NSRect(x: CGFloat(bar * 4), y: bounds.maxY - 1 - CGFloat(row), width: 3, height: 1).fill()
            }
        }
    }
}
