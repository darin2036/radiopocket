import Foundation

/// Just enough of RFC 8216 to play audio HLS: master variant choice, live media playlists, AES-128 keys.
enum HLSPlaylist {
    struct Variant: Equatable { var url: URL; var bandwidth: Int; var codecs: String }
    struct Key: Equatable { var url: URL; var iv: Data? }
    struct Segment: Equatable { var url: URL; var duration: Double; var sequence: Int; var key: Key?; var discontinuity: Bool }
    struct Media: Equatable {
        var targetDuration = 6.0
        var segments: [Segment] = []
        var ended = false
        var unsupported: String?
    }
    case master([Variant])
    case media(Media)

    static func looksLikePlaylist(_ text: String) -> Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#EXTM3U") && text.contains("#EXT-X-") || text.contains("#EXTINF") && text.contains("#EXT-X-TARGETDURATION") }

    static func parse(_ text: String, base: URL) throws -> HLSPlaylist {
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard lines.first?.hasPrefix("#EXTM3U") == true else { throw RadioError.message("This isn’t an HLS playlist.") }
        guard lines.count < 20_000 else { throw RadioError.message("The HLS playlist is too large.") }
        func resolve(_ reference: String) -> URL? {
            guard let url = URL(string: reference, relativeTo: base)?.absoluteURL, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
            return url
        }
        if lines.contains(where: { $0.hasPrefix("#EXT-X-STREAM-INF") }) {
            var variants: [Variant] = []
            var pending: [String: String]?
            for line in lines {
                if line.hasPrefix("#EXT-X-STREAM-INF:") { pending = attributes(String(line.dropFirst(18))) }
                else if !line.hasPrefix("#"), let attrs = pending, let url = resolve(line) {
                    variants.append(Variant(url: url, bandwidth: Int(attrs["BANDWIDTH"] ?? "") ?? 0, codecs: attrs["CODECS"] ?? "")); pending = nil
                }
            }
            guard !variants.isEmpty else { throw RadioError.message("This HLS playlist lists no playable streams.") }
            return .master(variants)
        }
        var media = Media()
        var sequence = 0, duration = 0.0, discontinuity = false
        var key: Key?
        for line in lines {
            if line.hasPrefix("#EXT-X-TARGETDURATION:") { media.targetDuration = max(1, min(60, Double(line.dropFirst(22)) ?? 6)) }
            else if line.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") { sequence = Int(line.dropFirst(22)) ?? 0 }
            else if line.hasPrefix("#EXTINF:") { duration = Double(line.dropFirst(8).split(separator: ",").first ?? "") ?? 0 }
            else if line == "#EXT-X-DISCONTINUITY" { discontinuity = true }
            else if line == "#EXT-X-ENDLIST" { media.ended = true }
            else if line.hasPrefix("#EXT-X-MAP") { media.unsupported = "This HLS stream uses fragmented MP4 segments." }
            else if line.hasPrefix("#EXT-X-KEY:") {
                let attrs = attributes(String(line.dropFirst(11)))
                switch attrs["METHOD"] ?? "NONE" {
                case "NONE": key = nil
                case "AES-128":
                    if let uri = attrs["URI"], let url = resolve(uri) { key = Key(url: url, iv: attrs["IV"].flatMap(hex)) }
                    else { media.unsupported = "The HLS encryption key address is invalid." }
                default: media.unsupported = "This HLS stream uses \(attrs["METHOD"] ?? "unknown") encryption."
                }
            } else if !line.hasPrefix("#"), let url = resolve(line) {
                media.segments.append(Segment(url: url, duration: duration, sequence: sequence, key: key, discontinuity: discontinuity))
                sequence += 1; duration = 0; discontinuity = false
            }
        }
        return .media(media)
    }

    /// Audio-only radio: prefer the highest-bandwidth non-video variant at or below 256 kb/s, else the smallest.
    static func choose(_ variants: [Variant]) -> Variant {
        let audio = variants.filter { !($0.codecs.contains("avc1") || $0.codecs.contains("hvc1") || $0.codecs.contains("hev1")) }
        let pool = audio.isEmpty ? variants : audio
        let fitting = pool.filter { $0.bandwidth > 0 && $0.bandwidth <= 256_000 }
        return fitting.max { $0.bandwidth < $1.bandwidth } ?? pool.min { $0.bandwidth < $1.bandwidth } ?? pool[0]
    }

    /// Default AES-128 IV: the segment sequence number as a 128-bit big-endian integer.
    static func iv(for segment: Segment) -> Data {
        if let iv = segment.key?.iv, iv.count == 16 { return iv }
        var iv = Data(repeating: 0, count: 16)
        var value = UInt64(max(0, segment.sequence))
        for index in stride(from: 15, through: 8, by: -1) { iv[index] = UInt8(value & 0xFF); value >>= 8 }
        return iv
    }

    static func attributes(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        var key = "", value = "", inKey = true, quoted = false
        func commit() { if !key.isEmpty { result[key.trimmingCharacters(in: .whitespaces)] = value }; key = ""; value = ""; inKey = true }
        for character in text {
            if inKey { if character == "=" { inKey = false } else { key.append(character) } }
            else if character == "\"" { quoted.toggle() }
            else if character == ",", !quoted { commit() }
            else { value.append(character) }
        }
        commit()
        return result
    }
    private static func hex(_ text: String) -> Data? {
        var digits = text.lowercased()
        if digits.hasPrefix("0x") { digits.removeFirst(2) }
        guard digits.count == 32 else { return nil }
        var data = Data(), index = digits.startIndex
        while index < digits.endIndex {
            let next = digits.index(index, offsetBy: 2)
            guard let byte = UInt8(digits[index..<next], radix: 16) else { return nil }
            data.append(byte); index = next
        }
        return data
    }
}
