import Foundation
import CEQ

struct EQPreset: Codable, Equatable {
    var name: String
    var preamp: Float
    var bands: [Float]
}
struct EQSettings: Codable {
    var enabled = false
    var preamp: Float = 0
    var bands: [Float] = Array(repeating: 0, count: 10)
    var preset = "Flat"
    var custom: [EQPreset] = []
    mutating func normalize() {
        preamp = preamp.isFinite ? min(12,max(-12,preamp)) : 0
        bands = (0..<10).map { i in i < bands.count && bands[i].isFinite ? min(12,max(-12,bands[i])) : 0 }
        custom = custom.filter { $0.bands.count == 10 && $0.bands.allSatisfy(\.isFinite) && $0.preamp.isFinite }
    }
}

final class Equalizer {
    var settings: EQSettings { didSet { settings.normalize(); apply(); changed?() } }
    var changed: (() -> Void)?
    private var dsp: OpaquePointer?
    var processedFrames: UInt64 { dsp.map { rp_eq_frames($0) } ?? 0 }
    var measuredRatio: Double { dsp.map { rp_eq_ratio($0) } ?? 1 }
    var available: Bool { dsp != nil }
    init(settings: EQSettings = EQSettings()) { self.settings = settings }
    func select(_ preset: EQPreset) {
        var next = settings
        next.preamp = preset.preamp; next.bands = preset.bands; next.preset = preset.name; next.enabled = true
        settings = next
    }
    func bind(_ pointer: OpaquePointer) { dsp = pointer; apply() }
    private func apply() {
        guard let dsp else { return }
        settings.bands.withUnsafeBufferPointer { rp_eq_set(dsp, settings.enabled ? 1 : 0, settings.preamp, $0.baseAddress!) }
    }
    func disconnect() { dsp = nil }
}
