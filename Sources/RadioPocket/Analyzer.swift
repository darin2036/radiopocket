import Foundation
import Accelerate

// MARK: - Settings

enum MiniVisMode: String, Codable, CaseIterable { case spectrum, fire, scope, off
    var title: String { ["spectrum": "Bars", "fire": "Fire", "scope": "Oscilloscope", "off": "Off"][rawValue]! }
    var next: MiniVisMode { self == .spectrum ? .fire : self == .fire ? .scope : .spectrum }
}
enum VisColoring: String, Codable, CaseIterable { case normal, fire, line
    var title: String { rawValue.capitalized }
    var next: VisColoring { self == .normal ? .fire : self == .fire ? .line : .normal }
}
enum BandWidth: String, Codable, CaseIterable { case thick, thin
    var title: String { rawValue.capitalized }
}
enum FirePalette: String, Codable, CaseIterable { case flame, blue, toxic, skin
    var title: String { ["flame": "Flame", "blue": "Blue Flame", "toxic": "Toxic Green", "skin": "Skin Colors"][rawValue]! }
}
enum ScopeStyle: String, Codable, CaseIterable { case lines, dots, solid
    var title: String { rawValue.capitalized }
}
enum VisRefresh: String, Codable, CaseIterable { case full, half, quarter
    var framesPerSecond: Double { self == .full ? 60 : self == .half ? 30 : 15 }
    var title: String { self == .full ? "Full (60 fps)" : self == .half ? "Half (30 fps)" : "Quarter (15 fps)" }
}
/// How long auto-cycle stays on one visualization before moving to the next.
enum VisCycleInterval {
    static let seconds = [5, 10, 15, 30, 60, 120, 300]
    static let standard = 15
    static func title(_ s: Int) -> String { s < 60 ? "\(s) seconds" : s == 60 ? "1 minute" : "\(s / 60) minutes" }
    static func nearest(_ s: Int) -> Int { seconds.min { abs($0 - s) < abs($1 - s) } ?? standard }
}
enum VisPanelMode: String, Codable, CaseIterable {
    case bars, scope, mirror, circle, spectrogram
    case ring, lissajous, waterfall, starfield, tunnel, plasma, kaleidoscope, fireworks, aurora, fire
    var title: String {
        switch self {
        case .bars: "Spectrum Bars"
        case .scope: "Oscilloscope"
        case .mirror: "Mirror Spectrum"
        case .circle: "Circular Spectrum"
        case .spectrogram: "Spectrogram"
        case .ring: "Waveform Ring"
        case .lissajous: "Vectorscope"
        case .waterfall: "Waterfall"
        case .starfield: "Starfield"
        case .tunnel: "Spectrum Tunnel"
        case .plasma: "Plasma"
        case .kaleidoscope: "Kaleidoscope"
        case .fireworks: "Fireworks"
        case .aurora: "Aurora"
        case .fire: "Fire"
        }
    }
    var next: VisPanelMode { let all = Self.allCases; return all[(all.firstIndex(of: self)! + 1) % all.count] }
    var previous: VisPanelMode { let all = Self.allCases; return all[(all.firstIndex(of: self)! + all.count - 1) % all.count] }
}

struct VisSettings: Codable, Equatable {
    var mini = MiniVisMode.spectrum
    var panel = VisPanelMode.bars
    var coloring = VisColoring.normal
    var peaks = true
    /// 0 (slowest) … 4 (fastest), like Winamp’s analyzer falloff choices.
    var falloff = 2
    /// 0 (slowest) … 4 (fastest) fall speed of the peak markers.
    var peakFalloff = 2
    var bandWidth = BandWidth.thick
    /// Flame reach, 0 (embers) … 4 (towering).
    var fireHeight = 2
    /// How much the flames flicker and sway, 0 (calm) … 4 (wild).
    var fireTurbulence = 2
    var firePalette = FirePalette.flame
    var scope = ScopeStyle.lines
    var refresh = VisRefresh.half
    var autoCycle = false
    /// Seconds each visualization stays up while auto-cycling; always one of `VisCycleInterval.seconds`.
    var cycleSeconds = VisCycleInterval.standard
    var overlay = true

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        var s = VisSettings()
        s.mini = (try? c.decodeIfPresent(MiniVisMode.self, forKey: .mini)) ?? s.mini
        s.panel = (try? c.decodeIfPresent(VisPanelMode.self, forKey: .panel)) ?? s.panel
        s.coloring = (try? c.decodeIfPresent(VisColoring.self, forKey: .coloring)) ?? s.coloring
        s.peaks = (try? c.decodeIfPresent(Bool.self, forKey: .peaks)) ?? s.peaks
        s.falloff = min(4, max(0, (try? c.decodeIfPresent(Int.self, forKey: .falloff)) ?? s.falloff))
        s.peakFalloff = min(4, max(0, (try? c.decodeIfPresent(Int.self, forKey: .peakFalloff)) ?? s.peakFalloff))
        s.bandWidth = (try? c.decodeIfPresent(BandWidth.self, forKey: .bandWidth)) ?? s.bandWidth
        s.fireHeight = min(4, max(0, (try? c.decodeIfPresent(Int.self, forKey: .fireHeight)) ?? s.fireHeight))
        s.fireTurbulence = min(4, max(0, (try? c.decodeIfPresent(Int.self, forKey: .fireTurbulence)) ?? s.fireTurbulence))
        s.firePalette = (try? c.decodeIfPresent(FirePalette.self, forKey: .firePalette)) ?? s.firePalette
        s.scope = (try? c.decodeIfPresent(ScopeStyle.self, forKey: .scope)) ?? s.scope
        s.refresh = (try? c.decodeIfPresent(VisRefresh.self, forKey: .refresh)) ?? s.refresh
        s.autoCycle = (try? c.decodeIfPresent(Bool.self, forKey: .autoCycle)) ?? s.autoCycle
        s.cycleSeconds = VisCycleInterval.nearest((try? c.decodeIfPresent(Int.self, forKey: .cycleSeconds)) ?? s.cycleSeconds)
        s.overlay = (try? c.decodeIfPresent(Bool.self, forKey: .overlay)) ?? s.overlay
        self = s
    }
}

// MARK: - Skin visualizer colours (VISCOLOR.TXT)

enum VisColors {
    typealias RGB = (r: UInt8, g: UInt8, b: UInt8)
    /// The stock Winamp 2.x palette: 0 background, 1 grid dots, 2…17 analyzer (top→bottom), 18…22 scope, 23 peaks.
    static let standard: [RGB] = [
        (0,0,0), (24,33,41), (239,49,16), (206,41,16), (214,90,0), (214,102,0), (214,115,0), (198,123,8),
        (222,165,24), (214,181,33), (189,222,41), (148,222,33), (41,206,16), (50,190,16), (57,181,16), (49,156,8),
        (41,148,0), (24,132,8), (255,255,255), (214,214,222), (181,189,189), (160,170,175), (148,156,165), (150,150,150),
    ]
    /// Accepts "r,g,b // comment" lines. Short or malformed files fall back to the stock colour for each missing entry.
    static func parse(_ text: String) -> [RGB] {
        var result: [RGB] = []
        for line in text.split(whereSeparator: \.isNewline) where result.count < 24 {
            let numbers = line.prefix { !"/;".contains($0) }.split { !($0.isNumber || $0 == "-") }.compactMap { Int($0) }
            guard numbers.count >= 3 else { continue }
            result.append((UInt8(min(255, max(0, numbers[0]))), UInt8(min(255, max(0, numbers[1]))), UInt8(min(255, max(0, numbers[2])))))
        }
        return result + standard.dropFirst(result.count)
    }
}

// MARK: - Analyzer

/// One display frame of audio analysis, all values normalised to 0…1 (scope −1…1).
struct VisFrame {
    var bars = [Float](repeating: 0, count: SpectrumAnalyzer.bands)
    var peaks = [Float](repeating: 0, count: SpectrumAnalyzer.bands)
    var scope = [Float](repeating: 0, count: SpectrumAnalyzer.scopeLength)
    var level: Float = 0
}

/// 2048-point Hann-windowed vDSP FFT folded into log-spaced bands, with Winamp-style bar falloff and peak hold.
final class SpectrumAnalyzer {
    static let bands = 76          // 19 mini-player bars × 4
    static let size = 2048
    static let scopeLength = 576   // Winamp’s oscilloscope sample count
    private let log2n = vDSP_Length(11)
    private let setup: FFTSetup
    private var window = [Float](repeating: 0, count: SpectrumAnalyzer.size)
    private var real = [Float](repeating: 0, count: SpectrumAnalyzer.size / 2)
    private var imag = [Float](repeating: 0, count: SpectrumAnalyzer.size / 2)
    private var windowed = [Float](repeating: 0, count: SpectrumAnalyzer.size)
    private var power = [Float](repeating: 0, count: SpectrumAnalyzer.size / 2)
    private var hold = [Double](repeating: 0, count: SpectrumAnalyzer.bands)
    private(set) var frame = VisFrame()
    static let floorDB: Float = -78, ceilingDB: Float = -22

    init() {
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        for i in 0..<Self.size { window[i] = 0.5 - 0.5 * cos(2 * Float.pi * Float(i) / Float(Self.size)) }
    }
    deinit { vDSP_destroy_fftsetup(setup) }

    /// Pure analysis of the newest `size` samples: returns the raw (unsmoothed) band levels 0…1.
    func bands(from samples: [Float], sampleRate: Double) -> [Float] {
        precondition(samples.count == Self.size)
        let n = Self.size
        vDSP_vmul(samples, 1, window, 1, &windowed, 1, vDSP_Length(n))
        real.withUnsafeMutableBufferPointer { r in imag.withUnsafeMutableBufferPointer { i in
            var split = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
            windowed.withUnsafeBufferPointer { source in
                source.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) { vDSP_ctoz($0, 2, &split, 1, vDSP_Length(n / 2)) }
            }
            vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
            vDSP_zvmags(&split, 1, &power, 1, vDSP_Length(n / 2))
        } }
        // A sine of amplitude A gives |Z| = A·N/2 after zrip’s ×2 and the Hann window’s 0.5 coherent gain, so A = 2·|Z| / N.
        let binWidth = Float(sampleRate) / Float(n)
        let low: Float = 45, high = Float(min(16000, sampleRate * 0.45))
        let ratio = pow(high / low, 1 / Float(Self.bands))
        var out = [Float](repeating: 0, count: Self.bands)
        for band in 0..<Self.bands {
            let lo = low * pow(ratio, Float(band)), hi = lo * ratio
            let first = Int((lo / binWidth).rounded(.down)), last = max(first, Int((hi / binWidth).rounded(.up)) - 1)
            var peak: Float = 0
            for bin in max(1, first)...min(n / 2 - 1, max(1, last)) { peak = max(peak, power[bin]) }
            let amplitude = 2 * peak.squareRoot() / Float(n)
            let center = (lo * hi).squareRoot()
            // Gentle +3 dB/octave tilt so treble is visible, as in classic analyzers.
            let db = 20 * log10(max(amplitude, 1e-9)) + 3 * log2(center / 500)
            out[band] = min(1, max(0, (db - Self.floorDB) / (Self.ceilingDB - Self.floorDB)))
        }
        return out
    }

    /// Smooths one raw analysis into the persistent display frame. `dt` is seconds since the previous call.
    func advance(raw: [Float], scope: [Float], dt: Double, falloff: Int, peakFalloff: Int? = nil) {
        let fall = Float([0.6, 1.1, 1.8, 2.8, 4.5][min(4, max(0, falloff))] * dt)       // full-scale units per second
        let peakFall = Float([0.35, 0.6, 0.9, 1.4, 2.2][min(4, max(0, peakFalloff ?? falloff))] * dt)
        var total: Float = 0
        for i in 0..<Self.bands {
            frame.bars[i] = raw[i] >= frame.bars[i] ? raw[i] : max(raw[i], frame.bars[i] - fall)
            if frame.bars[i] >= frame.peaks[i] { frame.peaks[i] = frame.bars[i]; hold[i] = 0.45 }
            else if hold[i] > 0 { hold[i] -= dt }
            else { frame.peaks[i] = max(frame.bars[i], frame.peaks[i] - peakFall) }
            total += frame.bars[i]
        }
        frame.level = total / Float(Self.bands)
        frame.scope = scope
    }

    /// Triggers on a rising zero crossing so a steady tone holds still, then returns `Self.scopeLength` samples.
    static func scopeWindow(from samples: [Float]) -> [Float] {
        let length = scopeLength
        guard samples.count >= length * 2 else { return [Float](repeating: 0, count: length) }
        let end = samples.count - length
        var start = samples.count - length * 2
        while start < end - 1, !(samples[start] <= 0 && samples[start + 1] > 0) { start += 1 }
        if start >= end - 1 { start = end }
        return Array(samples[start..<start + length])
    }

    func decay(dt: Double, falloff: Int, peakFalloff: Int? = nil) {
        advance(raw: [Float](repeating: 0, count: Self.bands), scope: [Float](repeating: 0, count: Self.scopeLength), dt: dt, falloff: falloff, peakFalloff: peakFalloff)
    }
    var isSilent: Bool { frame.bars.allSatisfy { $0 < 0.002 } && frame.peaks.allSatisfy { $0 < 0.002 } }
    func reset() { frame = VisFrame(); hold = [Double](repeating: 0, count: Self.bands) }
}
