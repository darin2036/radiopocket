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

/// Spatial audio styles, in the order the DSP's style table expects.
enum SpatialStyle: Int, CaseIterable, Codable {
    case off, studio, room, club, stage, hall, cathedral, surround, wide, headphones
    var title: String {
        switch self {
        case .off: "Off"
        case .studio: "Studio"
        case .room: "Room"
        case .club: "Club"
        case .stage: "Stage"
        case .hall: "Hall"
        case .cathedral: "Cathedral"
        case .surround: "Surround"
        case .wide: "Wide Stereo"
        case .headphones: "Headphones"
        }
    }
}
struct SpatialSettings: Codable, Equatable {
    var style = SpatialStyle.off
    /// How strongly the style is applied, 0...1.
    var amount: Float = 0.5
    /// Stereo width, 0 (mono) to 2; 1 leaves the stream as it is.
    var width: Float = 1
    mutating func normalize() {
        amount = amount.isFinite ? min(1, max(0, amount)) : 0.5
        width = width.isFinite ? min(2, max(0, width)) : 1
    }
}

final class Equalizer {
    var spatial = SpatialSettings() { didSet { spatial.normalize(); apply(); changed?() } }
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
        rp_space_set(dsp, Int32(spatial.style.rawValue), spatial.amount, spatial.width)
        settings.bands.withUnsafeBufferPointer { rp_eq_set(dsp, settings.enabled ? 1 : 0, settings.preamp, $0.baseAddress!) }
    }
    func disconnect() { dsp = nil }
}
