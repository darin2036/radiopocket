import Foundation

enum EQFile {
    static let header = Array("Winamp EQ library file v1.1".utf8) + [0x1a, 0x21, 0x2d, 0x2d]
    // Winamp's stock neutral byte is 31 (33 after the archive parser's inversion).
    static func decibels(_ byte: UInt8) -> Float { min(12, max(-12, Float(31 - Int(byte)) * 0.375)) }
    static func read(_ data: Data) throws -> [EQPreset] {
        let bytes = Array(data)
        guard bytes.count <= 1_048_576, bytes.starts(with: header), bytes.count > header.count,
              (bytes.count - header.count) % 268 == 0 else { throw RadioError.message("This isn’t a valid Winamp EQF preset library.") }
        var result: [EQPreset] = []
        for offset in stride(from: header.count, to: bytes.count, by: 268) {
            let nameBytes = bytes[offset..<offset+257].prefix { $0 != 0 }
            let name = String(bytes: nameBytes, encoding: .utf8) ?? String(bytes: nameBytes, encoding: .isoLatin1) ?? "Imported preset"
            let gains = Array(bytes[offset+257..<offset+268])
            guard gains.allSatisfy({ $0 <= 63 }) else { throw RadioError.message("The EQF file contains invalid gain values.") }
            result.append(EQPreset(name: name.isEmpty ? "Imported preset" : name, preamp: decibels(gains[10]), bands: gains.prefix(10).map(decibels)))
        }
        return result
    }
    static func write(_ preset: EQPreset) -> Data {
        var bytes = header
        var name = Array(preset.name.utf8.prefix(255))
        name += Array(repeating: 0, count: 257 - name.count)
        bytes += name
        bytes += (preset.bands + [preset.preamp]).map { UInt8(min(63, max(0, Int((31 - $0 / 0.375).rounded())))) }
        return Data(bytes)
    }
}
