import AppKit

/// Animation state for the visualizations that need more than the current analyzer frame:
/// beat detection, star positions, expanding rings and firework sparks. One per canvas.
final class VisState {
    struct Star { var x: CGFloat, y: CGFloat, z: CGFloat, band: Int }
    struct Ring { var age: Double; var bars: [Float] }
    /// Positions are fractions of the canvas; velocities are fractions per second.
    struct Spark { var x: CGFloat, y: CGFloat, vx: CGFloat, vy: CGFloat, life: Double, span: Double, tone: Float }

    static let ringLife = 2.4
    private static let sparkLimit = 700

    private(set) var phase = 0.0          // runs faster with louder music
    private(set) var rotation: CGFloat = 0
    private(set) var beat: Float = 0      // 1 on a detected beat, falling to 0
    private(set) var stars: [Star] = (0..<220).map { _ in VisState.newStar(z: .random(in: 0.05...1)) }
    private(set) var rings: [Ring] = []
    private(set) var sparks: [Spark] = []
    let fire = FireField()
    private var bassAverage: Float = 0
    private var sinceBeat = 0.0, sinceRing = 0.0, sinceBurst = 0.0

    private static func newStar(z: CGFloat) -> Star {
        Star(x: .random(in: -1...1), y: .random(in: -1...1), z: z, band: .random(in: 0..<SpectrumAnalyzer.bands))
    }

    func update(_ f: VisFrame, dt rawDelta: Double, aspect: CGFloat, mode: VisPanelMode, settings: VisSettings = VisSettings()) {
        let dt = min(0.1, max(0, rawDelta))
        if mode == .fire {
            fire.resize(columns: 120, rows: min(160, max(30, Int(120 / aspect))))
            fire.advance(dt: dt, bars: f.bars, settings: settings)
        }
        phase += dt * Double(0.5 + f.level * 3.5)
        rotation += CGFloat(dt) * CGFloat(0.12 + f.level * 0.9)
        beat = max(0, beat - Float(dt) * 3)
        let bass = f.bars[0..<10].reduce(0, +) / 10
        bassAverage += (bass - bassAverage) * Float(min(1, dt * 1.2))
        sinceBeat += dt; sinceRing += dt; sinceBurst += dt
        var hit = false
        if sinceBeat > 0.2, bass > 0.18, bass > bassAverage * 1.22 + 0.03 { hit = true; beat = 1; sinceBeat = 0 }

        let speed = CGFloat(dt) * CGFloat(0.12 + f.level * 1.1 + beat * 0.6)
        for i in stars.indices {
            stars[i].z -= speed
            if stars[i].z <= 0.03 { stars[i] = Self.newStar(z: 1) }
        }

        for i in rings.indices { rings[i].age += dt }
        rings.removeAll { $0.age > Self.ringLife }
        if mode == .tunnel, hit || sinceRing > 0.45 { rings.append(Ring(age: 0, bars: f.bars)); sinceRing = 0 }

        for i in sparks.indices {
            sparks[i].life -= dt
            sparks[i].vy -= CGFloat(0.35 * dt)
            sparks[i].x += sparks[i].vx * CGFloat(dt)
            sparks[i].y += sparks[i].vy * CGFloat(dt)
        }
        sparks.removeAll { $0.life <= 0 }
        if mode == .fireworks, hit || sinceBurst > 1.6, f.level > 0.03 { burst(f, aspect: aspect); sinceBurst = 0 }
    }

    private func burst(_ f: VisFrame, aspect: CGFloat) {
        guard sparks.count < Self.sparkLimit - 80 else { return }
        let x = CGFloat.random(in: 0.15...0.85), y = CGFloat.random(in: 0.45...0.85)
        let base = CGFloat(0.2 + f.level * 0.35)
        for _ in 0..<(24 + Int(f.level * 40)) {
            let angle = CGFloat.random(in: 0..<(2 * .pi)), speed = base * CGFloat.random(in: 0.35...1)
            let life = Double.random(in: 0.9...1.7)
            sparks.append(Spark(x: x, y: y, vx: cos(angle) * speed / aspect, vy: sin(angle) * speed, life: life, span: life, tone: .random(in: 0...1)))
        }
    }
}

// MARK: - Scenes

extension VisDraw {
    private static func glow(_ path: NSBezierPath, _ color: NSColor, width: CGFloat = 2) {
        path.lineJoinStyle = .round; path.lineCapStyle = .round
        path.lineWidth = width * 3.5; color.withAlphaComponent(0.2).setStroke(); path.stroke()
        path.lineWidth = width; color.setStroke(); path.stroke()
    }

    /// Catmull-Rom spline through the points.
    private static func smooth(_ points: [NSPoint]) -> NSBezierPath {
        let path = NSBezierPath()
        guard points.count > 1 else { return path }
        path.move(to: points[0])
        for i in 0..<(points.count - 1) {
            let p0 = points[max(0, i - 1)], p1 = points[i], p2 = points[i + 1], p3 = points[min(points.count - 1, i + 2)]
            path.curve(to: p2, controlPoint1: NSPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6),
                       controlPoint2: NSPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6))
        }
        return path
    }

    /// Draws an RGBX bitmap stretched over `frame`.
    static func drawBitmap(_ pixels: [UInt8], width: Int, height: Int, in frame: CGRect, smooth: Bool) {
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider, decode: nil, shouldInterpolate: smooth, intent: .defaultIntent),
              let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState(); context.interpolationQuality = smooth ? .high : .none
        context.draw(image, in: frame)
        context.restoreGState()
    }

    /// Waveform bent into a ring that swells on the beat, with the spectrum pointing inward.
    static func ring(_ f: VisFrame, _ s: VisSettings, _ c: [NSColor], _ rect: NSRect, _ st: VisState) {
        let size = min(rect.width, rect.height), center = NSPoint(x: rect.midX, y: rect.midY)
        let base = size * (0.27 + 0.025 * CGFloat(st.beat)), n = SpectrumAnalyzer.bands
        let spikes = NSBezierPath()
        for i in 0..<n {
            let angle = CGFloat.pi / 2 - 2 * .pi * (CGFloat(i) + 0.5) / CGFloat(n)
            let from = base * 0.93, to = from - max(1, CGFloat(f.bars[i]) * size * 0.2)
            spikes.move(to: NSPoint(x: center.x + cos(angle) * from, y: center.y + sin(angle) * from))
            spikes.line(to: NSPoint(x: center.x + cos(angle) * to, y: center.y + sin(angle) * to))
        }
        spikes.lineWidth = max(2, size * 0.008); spikes.lineCapStyle = .round
        ramp(f.level * 1.6, c).withAlphaComponent(0.8).setStroke(); spikes.stroke()

        let count = f.scope.count, drift = f.scope[count - 1] - f.scope[0]
        let wave = NSBezierPath()
        for i in 0..<count {
            let value = max(-1, min(1, (f.scope[i] - drift * Float(i) / Float(count - 1)) * 2.5))   // detrended so the ends meet
            let radius = base * 1.04 + CGFloat(value) * size * 0.13
            let angle = CGFloat.pi / 2 - 2 * .pi * CGFloat(i) / CGFloat(count)
            let point = NSPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
            if i == 0 { wave.move(to: point) } else { wave.line(to: point) }
        }
        wave.close()
        glow(wave, c[18], width: max(2, size * 0.006))
    }

    /// Vectorscope: the waveform plotted against a delayed copy of itself.
    static func lissajous(_ f: VisFrame, _ s: VisSettings, _ c: [NSColor], _ rect: NSRect, _ st: VisState) {
        let size = min(rect.width, rect.height), center = NSPoint(x: rect.midX, y: rect.midY)
        c[1].setStroke()
        let axes = NSBezierPath()
        axes.move(to: NSPoint(x: rect.minX, y: center.y)); axes.line(to: NSPoint(x: rect.maxX, y: center.y))
        axes.move(to: NSPoint(x: center.x, y: rect.minY)); axes.line(to: NSPoint(x: center.x, y: rect.maxY))
        axes.appendOval(in: NSRect(x: center.x - size * 0.45, y: center.y - size * 0.45, width: size * 0.9, height: size * 0.9))
        axes.lineWidth = 1; axes.stroke()
        let count = f.scope.count, delay = 20 + Int(20 * (1 + sin(st.phase * 0.4)))
        let path = NSBezierPath()
        for i in 0..<(count - delay) {
            let x = CGFloat(max(-1, min(1, f.scope[i] * 2.5))), y = CGFloat(max(-1, min(1, f.scope[i + delay] * 2.5)))
            let point = NSPoint(x: center.x + x * size * 0.45, y: center.y + y * size * 0.45)
            if i == 0 { path.move(to: point) } else { path.line(to: point) }
        }
        glow(path, ramp(0.25 + f.level * 1.5, c), width: max(1.5, size * 0.004))
    }

    /// Joy-Division-style ridgelines: each recent spectrum is a hill, older ones recede and are hidden by newer ones.
    static func waterfall(_ history: [[Float]], _ c: [NSColor], _ rect: NSRect) {
        let rows = stride(from: history.count - 1, through: 0, by: -3).prefix(30).reversed().map { history[$0] }
        guard !rows.isEmpty else { return }
        let n = SpectrumAnalyzer.bands
        for (r, bars) in rows.enumerated() {
            let near = rows.count > 1 ? CGFloat(r) / CGFloat(rows.count - 1) : 1
            let width = rect.width * (0.5 + 0.5 * near), x0 = rect.midX - width / 2
            let base = rect.minY + rect.height * (0.06 + 0.5 * (1 - near)), amp = rect.height * (0.16 + 0.14 * near)
            let ridge = NSBezierPath()
            ridge.move(to: NSPoint(x: x0, y: base))
            for i in 0..<n {
                let u = CGFloat(i) / CGFloat(n - 1)
                ridge.line(to: NSPoint(x: x0 + width * u, y: base + CGFloat(bars[i]) * amp * min(1, 5 * min(u, 1 - u))))
            }
            ridge.line(to: NSPoint(x: x0 + width, y: base))
            let hill = ridge.copy() as! NSBezierPath
            hill.line(to: NSPoint(x: x0 + width, y: rect.minY)); hill.line(to: NSPoint(x: x0, y: rect.minY)); hill.close()
            c[0].setFill(); hill.fill()
            ramp((bars.max() ?? 0) * 1.1, c).withAlphaComponent(0.45 + 0.55 * near).setStroke()
            ridge.lineWidth = 1 + near; ridge.lineJoinStyle = .round; ridge.stroke()
        }
    }

    /// Flying through stars; speed follows the loudness, and each star glows with its own frequency band.
    static func starfield(_ f: VisFrame, _ s: VisSettings, _ c: [NSColor], _ rect: NSRect, _ st: VisState) {
        let scale = max(rect.width, rect.height) * 0.25
        let streak = CGFloat(0.012 + f.level * 0.05 + st.beat * 0.04)
        for star in st.stars {
            let near = 1 - star.z, level = f.bars[star.band]
            let far = star.z + streak
            let a = NSPoint(x: rect.midX + star.x / star.z * scale, y: rect.midY + star.y / star.z * scale)
            let b = NSPoint(x: rect.midX + star.x / far * scale, y: rect.midY + star.y / far * scale)
            guard rect.insetBy(dx: -20, dy: -20).contains(a) else { continue }
            let path = NSBezierPath(); path.move(to: a); path.line(to: b)
            path.lineWidth = 0.6 + near * 2.4 * CGFloat(1 + level); path.lineCapStyle = .round
            ramp(level, c).withAlphaComponent(min(1, near * 1.5) * CGFloat(0.4 + 0.6 * level)).setStroke(); path.stroke()
        }
    }

    /// A new ring of the spectrum is launched down the tunnel on every beat.
    static func tunnel(_ f: VisFrame, _ s: VisSettings, _ c: [NSColor], _ rect: NSRect, _ st: VisState) {
        let size = min(rect.width, rect.height), center = NSPoint(x: rect.midX, y: rect.midY), reach = max(rect.width, rect.height) * 0.6
        let points = SpectrumAnalyzer.bands * 2
        for ring in st.rings {
            let life = CGFloat(ring.age / VisState.ringLife)
            let radius = reach * pow(life, 1.7)
            let path = NSBezierPath()
            for k in 0..<points {
                let bar = ring.bars[k < SpectrumAnalyzer.bands ? k : points - 1 - k]
                let r = radius * (1 + 0.22 * CGFloat(bar) * (1 - life))
                let angle = 2 * CGFloat.pi * CGFloat(k) / CGFloat(points) + st.rotation * 0.3
                let point = NSPoint(x: center.x + cos(angle) * r, y: center.y + sin(angle) * r)
                if k == 0 { path.move(to: point) } else { path.line(to: point) }
            }
            path.close(); path.lineWidth = 1 + 3 * life; path.lineJoinStyle = .round
            ramp(ring.bars.reduce(0, +) / Float(points / 2) * 1.5, c).withAlphaComponent(pow(1 - life, 0.6)).setStroke(); path.stroke()
        }
        let core = size * 0.012 * (1 + CGFloat(st.beat) * 1.5 + CGFloat(f.level))
        c[18].withAlphaComponent(0.9).setFill()
        NSBezierPath(ovalIn: NSRect(x: center.x - core, y: center.y - core, width: core * 2, height: core * 2)).fill()
    }

    /// Classic sine plasma at low resolution, coloured from the skin palette and driven faster by the music.
    static func plasma(_ f: VisFrame, _ c: [NSColor], _ rect: NSRect, _ st: VisState) {
        let cols = 96, rows = max(16, min(96, Int((96 * rect.height / max(1, rect.width)).rounded())))
        let anchors = (0..<16).map { i -> (Double, Double, Double) in
            let color = c[17 - i].usingColorSpace(.sRGB) ?? .black
            return (Double(color.redComponent), Double(color.greenComponent), Double(color.blueComponent))
        }
        let lut = (0..<256).map { k -> (Double, Double, Double) in
            let p = Double(k) / 256, tri = (p < 0.5 ? p * 2 : 2 - 2 * p) * 15
            let lo = min(14, Int(tri)), mix = tri - Double(lo), a = anchors[lo], b = anchors[lo + 1]
            return (a.0 + (b.0 - a.0) * mix, a.1 + (b.1 - a.1) * mix, a.2 + (b.2 - a.2) * mix)
        }
        let t = st.phase, kick = Double(st.beat) * 0.6
        let brightness = 0.4 + 0.6 * min(1, Double(f.level) * 2.2 + Double(st.beat) * 0.3)
        var pixels = [UInt8](repeating: 255, count: cols * rows * 4)
        for y in 0..<rows {
            let v = Double(y) / Double(cols) * 14
            for x in 0..<cols {
                let u = Double(x) / Double(cols) * 14
                let sum = sin(u + t) + sin(v * 1.3 + t * 1.2) + sin((u + v) * 0.8 + t * 0.7)
                    + sin(hypot(u - 7 + 3 * sin(t * 0.5), v - 4 + 3 * cos(t * 0.4)) * 0.9 - t * (1 + kick))
                let index = Int((sum + 4) / 8 * 255 + t * 12) & 255
                let color = lut[index], offset = ((rows - 1 - y) * cols + x) * 4
                pixels[offset] = UInt8(min(255, color.0 * brightness * 255))
                pixels[offset + 1] = UInt8(min(255, color.1 * brightness * 255))
                pixels[offset + 2] = UInt8(min(255, color.2 * brightness * 255))
            }
        }
        drawBitmap(pixels, width: cols, height: rows, in: rect, smooth: true)
    }

    /// The spectrum folded into eight rotating mirrored petals.
    static func kaleidoscope(_ f: VisFrame, _ s: VisSettings, _ c: [NSColor], _ rect: NSRect, _ st: VisState) {
        let size = min(rect.width, rect.height), center = NSPoint(x: rect.midX, y: rect.midY)
        let segments = 8, wedge = 2 * CGFloat.pi / CGFloat(segments), n = SpectrumAnalyzer.bands
        let inner = size * 0.04, reach = size * 0.44 * (1 + 0.08 * CGFloat(st.beat))
        for layer in 0..<2 {
            let source = layer == 0 ? f.bars : f.peaks, scale = layer == 0 ? reach : reach * 0.55
            for segment in 0..<segments {
                let petal = NSBezierPath(), edge = NSBezierPath()
                petal.move(to: center)
                for i in 0..<n {
                    let fraction = (CGFloat(i) + 0.5) / CGFloat(n)
                    let angle = st.rotation * (layer == 0 ? 1 : -1.4) + CGFloat(segment) * wedge + (segment % 2 == 1 ? 1 - fraction : fraction) * wedge
                    let radius = inner + CGFloat(source[i]) * scale
                    let point = NSPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
                    petal.line(to: point)
                    if i == 0 { edge.move(to: point) } else { edge.line(to: point) }
                }
                petal.close()
                ramp(f.level * 1.8 + Float(layer) * 0.35, c).withAlphaComponent(layer == 0 ? 0.35 : 0.18).setFill(); petal.fill()
                edge.lineWidth = layer == 0 ? 1.5 : 1; edge.lineJoinStyle = .round
                (layer == 0 ? c[18] : c[19]).withAlphaComponent(0.85).setStroke(); edge.stroke()
            }
        }
    }

    /// Bursts launched on the beat, with the spectrum as a skyline.
    static func fireworks(_ f: VisFrame, _ s: VisSettings, _ c: [NSColor], _ rect: NSRect, _ st: VisState) {
        let n = SpectrumAnalyzer.bands, slot = rect.width / CGFloat(n)
        for i in 0..<n where f.bars[i] > 0.01 {
            ramp(f.bars[i], c).withAlphaComponent(0.5).setFill()
            NSRect(x: rect.minX + CGFloat(i) * slot + slot * 0.1, y: rect.minY, width: slot * 0.8, height: CGFloat(f.bars[i]) * rect.height * 0.1).fill()
        }
        let dot = max(1.2, min(rect.width, rect.height) * 0.004)
        for spark in st.sparks {
            let remaining = CGFloat(spark.life / spark.span)
            let head = NSPoint(x: rect.minX + spark.x * rect.width, y: rect.minY + spark.y * rect.height)
            let tail = NSPoint(x: head.x - spark.vx * rect.width * 0.04, y: head.y - spark.vy * rect.height * 0.04)
            let path = NSBezierPath(); path.move(to: head); path.line(to: tail)
            path.lineWidth = dot * (0.6 + remaining) * 1.6; path.lineCapStyle = .round
            ramp(spark.tone, c).withAlphaComponent(min(1, remaining * 1.5)).setStroke(); path.stroke()
        }
    }

    /// Three layers of smooth, rippling spectrum curves filled with a fading gradient.
    static func aurora(_ f: VisFrame, _ s: VisSettings, _ c: [NSColor], _ rect: NSRect, _ st: VisState) {
        let n = SpectrumAnalyzer.bands, base = rect.minY + rect.height * 0.08
        let tones: [Float] = [0.9, 0.55, 0.2]
        for layer in [2, 1, 0] {
            let shift = layer == 1 ? Int(sin(st.phase * 0.5 + 1) * 6) : 0
            let scale = [1, 0.72, 0.5][layer] * rect.height * 0.75
            let points = (0..<n).map { i -> NSPoint in
                let u = CGFloat(i) / CGFloat(n - 1)
                let value = layer == 2 ? f.peaks[i] : f.bars[min(n - 1, max(0, i + shift))]
                let ripple = sin(u * 9 + CGFloat(st.phase) * CGFloat(1 + layer)) * rect.height * 0.015
                return NSPoint(x: rect.minX + rect.width * u, y: base + CGFloat(value) * scale + ripple)
            }
            let curve = smooth(points), area = curve.copy() as! NSBezierPath
            area.line(to: NSPoint(x: rect.maxX, y: rect.minY)); area.line(to: NSPoint(x: rect.minX, y: rect.minY)); area.close()
            let tint = ramp(tones[layer], c)
            NSGraphicsContext.saveGraphicsState()
            area.addClip()
            NSGradient(colors: [tint.withAlphaComponent(0.04), tint.withAlphaComponent(0.8)])?.draw(in: rect, angle: 90)
            NSGraphicsContext.restoreGraphicsState()
            curve.lineWidth = 2; curve.lineJoinStyle = .round
            tint.setStroke(); curve.stroke()
        }
    }
}
