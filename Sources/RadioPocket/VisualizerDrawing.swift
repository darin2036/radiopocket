import AppKit

/// Pure drawing for every visualization. Mini drawing works in the player’s flipped 275×116 pixel space;
/// panel drawing works in an ordinary (y-up) view rect.
enum VisDraw {
    static let miniSlot = NSRect(x: 24, y: 43, width: 76, height: 16)

    static func ramp(_ value: Float, _ colors: [NSColor]) -> NSColor { colors[17 - min(15, max(0, Int((value * 15).rounded())))] }

    // MARK: Mini visualizer (76 × 16, 19 bars of 3 px + 1 px gap)

    static func mini(_ hub: VisualizerHub, in slot: NSRect = miniSlot) {
        let c = hub.colors, f = hub.frame, s = hub.settings
        c[0].setFill(); slot.fill()
        if s.mini == .fire { miniFire(hub, in: slot); return }
        c[1].setFill()
        for y in stride(from: 0, to: 16, by: 2) { for x in stride(from: 0, to: 76, by: 2) { NSRect(x: slot.minX + CGFloat(x), y: slot.minY + CGFloat(y), width: 1, height: 1).fill() } }
        switch s.mini {
        case .spectrum, .fire:
            let coloring = s.coloring
            for bar in 0..<19 {
                let range = (bar * 4)..<(bar * 4 + 4)
                let level = range.map { f.bars[$0] }.max() ?? 0
                let height = Int((level * 16).rounded())
                let thin = s.bandWidth == .thin, w: CGFloat = thin ? 1 : 3, x = slot.minX + CGFloat(bar * 4) + (thin ? 1 : 0)
                if height > 0 {
                    switch coloring {
                    case .normal:
                        for row in 0..<height { c[17 - row].setFill(); NSRect(x: x, y: slot.maxY - 1 - CGFloat(row), width: w, height: 1).fill() }
                    case .fire:
                        c[17 - (height - 1)].setFill(); NSRect(x: x, y: slot.maxY - CGFloat(height), width: w, height: CGFloat(height)).fill()
                    case .line:
                        c[17 - (height - 1)].setFill(); NSRect(x: x + (thin ? 0 : 1), y: slot.maxY - CGFloat(height), width: 1, height: CGFloat(height)).fill()
                    }
                }
                if s.peaks {
                    let peak = Int(((range.map { f.peaks[$0] }.max() ?? 0) * 16).rounded())
                    if peak > 0 { c[23].setFill(); NSRect(x: x, y: slot.maxY - CGFloat(peak), width: w, height: 1).fill() }
                }
            }
        case .scope:
            var previous = 8
            for x in 0..<76 {
                let sample = f.scope[min(f.scope.count - 1, x * f.scope.count / 76)]
                let y = min(15, max(0, Int((8 - sample * 2.5 * 8).rounded())))
                c[18 + min(4, abs(y - 8) / 2)].setFill()
                switch s.scope {
                case .dots: NSRect(x: slot.minX + CGFloat(x), y: slot.minY + CGFloat(y), width: 1, height: 1).fill()
                case .lines:
                    let low = min(previous, y), high = max(previous, y)
                    NSRect(x: slot.minX + CGFloat(x), y: slot.minY + CGFloat(low), width: 1, height: CGFloat(high - low + 1)).fill()
                case .solid:
                    let low = min(8, y), high = max(8, y)
                    NSRect(x: slot.minX + CGFloat(x), y: slot.minY + CGFloat(low), width: 1, height: CGFloat(high - low + 1)).fill()
                }
                previous = y
            }
        case .off: break
        }
    }

    // MARK: Window / full-screen visualizations

    static func panel(_ mode: VisPanelMode, hub: VisualizerHub, in rect: NSRect, history: [[Float]], state: VisState) {
        let c = hub.colors, f = hub.frame, s = hub.settings
        c[0].setFill(); rect.fill()
        switch mode {
        case .bars: bars(f, s, c, rect)
        case .scope: scope(f, s, c, rect)
        case .mirror: mirror(f, s, c, rect)
        case .circle: circle(f, s, c, rect)
        case .spectrogram: spectrogram(history, c, rect)
        case .ring: ring(f, s, c, rect, state)
        case .lissajous: lissajous(f, s, c, rect, state)
        case .waterfall: waterfall(history, c, rect)
        case .starfield: starfield(f, s, c, rect, state)
        case .tunnel: tunnel(f, s, c, rect, state)
        case .plasma: plasma(f, c, rect, state)
        case .kaleidoscope: kaleidoscope(f, s, c, rect, state)
        case .fireworks: fireworks(f, s, c, rect, state)
        case .aurora: aurora(f, s, c, rect, state)
        case .fire: fire(s, c, rect, state)
        }
    }

    private static func bars(_ f: VisFrame, _ s: VisSettings, _ c: [NSColor], _ rect: NSRect) {
        let n = SpectrumAnalyzer.bands, slot = rect.width / CGFloat(n), barWidth = max(1, slot * (s.bandWidth == .thin ? 0.36 : 0.74))
        let segments = max(10, Int(rect.height / 12)), segmentHeight = rect.height / CGFloat(segments), gap = max(1, segmentHeight * 0.16)
        for i in 0..<n {
            let x = rect.minX + CGFloat(i) * slot + (slot - barWidth) / 2
            let lit = min(segments, Int((f.bars[i] * Float(segments)).rounded()))
            if lit > 0 {
                switch s.coloring {
                case .normal:
                    for seg in 0..<lit {
                        c[17 - Int(Float(seg) / Float(max(1, segments - 1)) * 15)].setFill()
                        NSRect(x: x, y: rect.minY + CGFloat(seg) * segmentHeight, width: barWidth, height: segmentHeight - gap).fill()
                    }
                case .fire:
                    ramp(f.bars[i], c).setFill()
                    for seg in 0..<lit { NSRect(x: x, y: rect.minY + CGFloat(seg) * segmentHeight, width: barWidth, height: segmentHeight - gap).fill() }
                case .line:
                    ramp(f.bars[i], c).setFill()
                    NSRect(x: x + barWidth / 2 - 1, y: rect.minY, width: 2, height: CGFloat(lit) * segmentHeight - gap).fill()
                }
            }
            if s.peaks {
                let peak = min(segments, Int((f.peaks[i] * Float(segments)).rounded()))
                if peak > 0 { c[23].setFill(); NSRect(x: x, y: rect.minY + CGFloat(peak - 1) * segmentHeight, width: barWidth, height: max(2, segmentHeight - gap)).fill() }
            }
        }
    }

    private static func scope(_ f: VisFrame, _ s: VisSettings, _ c: [NSColor], _ rect: NSRect) {
        let mid = rect.midY, count = f.scope.count
        c[1].setFill(); NSRect(x: rect.minX, y: mid, width: rect.width, height: 1).fill()
        func point(_ i: Int) -> NSPoint { NSPoint(x: rect.minX + rect.width * CGFloat(i) / CGFloat(count - 1), y: mid + CGFloat(max(-1, min(1, f.scope[i] * 2.5))) * rect.height * 0.45) }
        switch s.scope {
        case .lines:
            let path = NSBezierPath(); path.move(to: point(0))
            for i in 1..<count { path.line(to: point(i)) }
            path.lineJoinStyle = .round
            path.lineWidth = 7; c[19].withAlphaComponent(0.22).setStroke(); path.stroke()
            path.lineWidth = 2; c[18].setStroke(); path.stroke()
        case .dots:
            c[18].setFill()
            for i in stride(from: 0, to: count, by: 2) { let p = point(i); NSRect(x: p.x - 1.5, y: p.y - 1.5, width: 3, height: 3).fill() }
        case .solid:
            let width = max(1, rect.width / CGFloat(count) + 0.5)
            for i in 0..<count {
                let p = point(i)
                c[18 + min(4, Int(abs(p.y - mid) / rect.height * 10))].setFill()
                NSRect(x: p.x, y: min(mid, p.y), width: width, height: max(1, abs(p.y - mid))).fill()
            }
        }
    }

    private static func mirror(_ f: VisFrame, _ s: VisSettings, _ c: [NSColor], _ rect: NSRect) {
        let n = SpectrumAnalyzer.bands, slot = rect.width / CGFloat(n), barWidth = max(1, slot * 0.8), mid = rect.midY
        for i in 0..<n {
            let x = rect.minX + CGFloat(i) * slot + (slot - barWidth) / 2
            let half = CGFloat(f.bars[i]) * rect.height / 2
            if half > 0.5 {
                (s.coloring == .normal ? c[17 - min(15, Int(CGFloat(f.bars[i]) * 15))] : ramp(f.bars[i], c)).setFill()
                NSBezierPath(roundedRect: NSRect(x: x, y: mid - half, width: barWidth, height: half * 2), xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
            }
            if s.peaks {
                let peak = CGFloat(f.peaks[i]) * rect.height / 2
                if peak > 1 { c[23].setFill(); NSRect(x: x, y: mid + peak, width: barWidth, height: 2).fill(); NSRect(x: x, y: mid - peak - 2, width: barWidth, height: 2).fill() }
            }
        }
    }

    private static func circle(_ f: VisFrame, _ s: VisSettings, _ c: [NSColor], _ rect: NSRect) {
        let n = SpectrumAnalyzer.bands, size = min(rect.width, rect.height)
        let center = NSPoint(x: rect.midX, y: rect.midY), inner = size * (0.17 + 0.03 * CGFloat(f.level)), reach = size * 0.30
        let ring = NSBezierPath(ovalIn: NSRect(x: center.x - inner, y: center.y - inner, width: inner * 2, height: inner * 2))
        ring.lineWidth = 2; c[1].setStroke(); ring.stroke()
        let width = max(2, 2 * .pi * inner / CGFloat(n) * 0.6)
        for i in 0..<n {
            let angle = CGFloat.pi / 2 - 2 * .pi * CGFloat(i) / CGFloat(n)
            let direction = NSPoint(x: cos(angle), y: sin(angle))
            let path = NSBezierPath()
            path.move(to: NSPoint(x: center.x + direction.x * inner, y: center.y + direction.y * inner))
            let length = inner + max(1, CGFloat(f.bars[i]) * reach)
            path.line(to: NSPoint(x: center.x + direction.x * length, y: center.y + direction.y * length))
            path.lineWidth = width; path.lineCapStyle = .round
            ramp(f.bars[i], c).setStroke(); path.stroke()
            if s.peaks, f.peaks[i] > 0.02 {
                let peak = inner + CGFloat(f.peaks[i]) * reach + width
                c[23].setFill(); NSBezierPath(ovalIn: NSRect(x: center.x + direction.x * peak - width / 2, y: center.y + direction.y * peak - width / 2, width: width, height: width)).fill()
            }
        }
    }

    private static func spectrogram(_ history: [[Float]], _ c: [NSColor], _ rect: NSRect) {
        guard !history.isEmpty else { return }
        let rows = SpectrumAnalyzer.bands, columns = history.count
        var pixels = [UInt8](repeating: 0, count: rows * columns * 4)
        for (x, bars) in history.enumerated() {
            for y in 0..<rows {
                let value = bars[y]
                let color = ramp(value, c).usingColorSpace(.sRGB) ?? .black
                let brightness = CGFloat(min(1, value * 1.6))
                let offset = ((rows - 1 - y) * columns + x) * 4
                pixels[offset] = UInt8(color.redComponent * brightness * 255); pixels[offset + 1] = UInt8(color.greenComponent * brightness * 255)
                pixels[offset + 2] = UInt8(color.blueComponent * brightness * 255); pixels[offset + 3] = 255
            }
        }
        let width = rect.width * CGFloat(columns) / CGFloat(SpectrogramLimit.columns)
        drawBitmap(pixels, width: columns, height: rows, in: CGRect(x: rect.maxX - width, y: rect.minY, width: width, height: rect.height), smooth: false)
    }
}

enum SpectrogramLimit { static let columns = 220 }
