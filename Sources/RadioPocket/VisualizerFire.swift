import AppKit

/// A cellular flame simulation: the spectrum feeds heat in along the bottom row, and the heat rises,
/// spreads sideways and cools. Because bars are only a heat source, the result reads as one bank of fire.
final class FireField {
    private(set) var columns = 0, rows = 0
    private var heat: [Float] = [], scratch: [Float] = []
    private var accumulator = 0.0
    private(set) var isHot = false
    static let step = 1.0 / 30

    func resize(columns: Int, rows: Int) {
        guard columns != self.columns || rows != self.rows else { return }
        self.columns = columns; self.rows = rows
        heat = [Float](repeating: 0, count: columns * rows); scratch = heat; isHot = false
    }

    func reset() { heat = [Float](repeating: 0, count: heat.count); isHot = false }

    /// Advances in fixed 30 Hz steps so the flames look the same at any refresh rate.
    func advance(dt: Double, bars: [Float], settings s: VisSettings) {
        guard columns > 2, rows > 2 else { return }
        accumulator = min(0.2, accumulator + dt)
        while accumulator >= Self.step { accumulator -= Self.step; stepOnce(bars: bars, settings: s) }
    }

    private func stepOnce(bars: [Float], settings s: VisSettings) {
        let reach = [0.28, 0.42, 0.58, 0.78, 1.0][min(4, max(0, s.fireHeight))]
        let cooling = Float(1 / (Double(rows) * reach))
        let sway = [0, 1, 1, 2, 3][min(4, max(0, s.fireTurbulence))]
        let flicker = Float([0.1, 0.25, 0.4, 0.6, 0.85][min(4, max(0, s.fireTurbulence))])
        let seedRows = max(1, rows / 12)

        for x in 0..<columns {
            let position = Float(x) / Float(columns - 1) * Float(bars.count - 1)
            let i = Int(position), j = min(bars.count - 1, i + 1), t = position - Float(i)
            let level = min(1, (bars[i] * (1 - t) + bars[j] * t) * 1.15)
            for y in 0..<seedRows {
                let seed = level * (1 - flicker * 0.5 * Float.random(in: 0...1))
                if seed > heat[y * columns + x] { heat[y * columns + x] = seed }
            }
        }

        var peak: Float = 0
        for y in 1..<rows {
            for x in 0..<columns {
                let drift = sway == 0 ? 0 : Int.random(in: -sway...sway)
                let sx = min(columns - 1, max(0, x + drift)), left = max(0, sx - 1), right = min(columns - 1, sx + 1)
                let below = (y - 1) * columns
                var value = (heat[below + left] + 2 * heat[below + sx] + heat[below + right]) * 0.25
                value -= cooling * (1 - flicker * 0.5 + flicker * Float.random(in: 0...1))
                value = max(0, value)
                scratch[y * columns + x] = value
                if value > peak { peak = value }
            }
        }
        for x in 0..<columns { scratch[x] = heat[x] * 0.8 }
        swap(&heat, &scratch)
        isHot = peak > 0.03
        if !isHot { reset() }
    }

    /// RGBX pixels, top row first.
    func pixels(palette: FirePalette, colors: [NSColor], flipped: Bool = false) -> [UInt8] {
        let lut = Self.lut(palette, colors)
        var out = [UInt8](repeating: 255, count: columns * rows * 4)
        for y in 0..<rows {
            let rowStart = (flipped ? y : rows - 1 - y) * columns * 4
            for x in 0..<columns {
                let v = min(255, Int(heat[y * columns + x] * 255)), o = rowStart + x * 4
                out[o] = lut[v * 3]; out[o + 1] = lut[v * 3 + 1]; out[o + 2] = lut[v * 3 + 2]
            }
        }
        return out
    }

    private static func lut(_ palette: FirePalette, _ colors: [NSColor]) -> [UInt8] {
        typealias Stop = (at: Float, rgb: (Float, Float, Float))
        let stops: [Stop]
        switch palette {
        case .flame: stops = [(0, (0, 0, 0)), (0.18, (70, 4, 0)), (0.4, (190, 36, 0)), (0.62, (255, 110, 0)), (0.82, (255, 200, 40)), (1, (255, 250, 200))]
        case .blue: stops = [(0, (0, 0, 0)), (0.2, (4, 14, 80)), (0.45, (0, 90, 220)), (0.7, (60, 180, 255)), (1, (225, 248, 255))]
        case .toxic: stops = [(0, (0, 0, 0)), (0.2, (0, 50, 6)), (0.45, (20, 160, 20)), (0.7, (150, 240, 40)), (1, (240, 255, 200))]
        case .skin:
            var list: [Stop] = [(0, (0, 0, 0))]
            for i in 0..<16 {
                let c = colors[17 - i].usingColorSpace(.sRGB) ?? .white
                let at: Float = 0.1 + 0.9 * Float(i) / 15
                list.append((at, (Float(c.redComponent) * 255, Float(c.greenComponent) * 255, Float(c.blueComponent) * 255)))
            }
            stops = list
        }
        var out = [UInt8](repeating: 0, count: 256 * 3)
        for v in 0..<256 {
            let t = Float(v) / 255
            let hi = stops.firstIndex { $0.at >= t } ?? stops.count - 1, lo = max(0, hi - 1)
            let span = max(0.0001, stops[hi].at - stops[lo].at)
            let f: Float = hi == lo ? 0 : (t - stops[lo].at) / span
            let a = stops[lo].rgb, b = stops[hi].rgb
            let r: Float = a.0 + (b.0 - a.0) * f, g: Float = a.1 + (b.1 - a.1) * f, bl: Float = a.2 + (b.2 - a.2) * f
            out[v * 3] = UInt8(min(255, r)); out[v * 3 + 1] = UInt8(min(255, g)); out[v * 3 + 2] = UInt8(min(255, bl))
        }
        return out
    }
}

extension VisDraw {
    /// Window / full-screen flames: the field is sized to the canvas shape and smoothed up to full size.
    static func fire(_ s: VisSettings, _ c: [NSColor], _ rect: NSRect, _ st: VisState) {
        let field = st.fire
        guard field.columns > 0 else { return }
        drawBitmap(field.pixels(palette: s.firePalette, colors: c), width: field.columns, height: field.rows, in: rect, smooth: true)
    }

    /// Player mini visualizer flames at the native 76 × 16 pixel size.
    static func miniFire(_ hub: VisualizerHub, in slot: NSRect) {
        let field = hub.miniFire
        guard field.columns > 0 else { return }
        drawBitmap(field.pixels(palette: hub.settings.firePalette, colors: hub.colors, flipped: true), width: field.columns, height: field.rows, in: slot, smooth: false)
    }
}
