import Foundation
import Compression

/// A minimal ZIP reader for platforms that can't launch `unzip`. Reads stored and deflated entries into bounded memory
/// and never writes archive paths to disk.
struct ZipReader {
    struct Entry { let name: String; let method: UInt16; let compressedSize: Int; let size: Int; let offset: Int; let encrypted: Bool }
    private let data: Data
    let entries: [Entry]

    init(url: URL) throws {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        self.data = data
        func u16(_ at: Int) -> Int { Int(data[data.startIndex + at]) | Int(data[data.startIndex + at + 1]) << 8 }
        func u32(_ at: Int) -> Int { u16(at) | u16(at + 2) << 16 }
        let damaged = RadioError.message("The skin ZIP is damaged, encrypted, or unreadable.")
        guard data.count >= 22 else { throw damaged }
        var end = data.count - 22
        let lowest = max(0, data.count - 22 - 65_535)
        while end >= lowest, u32(end) != 0x06054b50 { end -= 1 }
        guard end >= lowest else { throw damaged }
        let count = u16(end + 10), directorySize = u32(end + 12), directory = u32(end + 16)
        guard directory + directorySize <= data.count, count <= 65_535 else { throw damaged }
        var position = directory, found: [Entry] = []
        for _ in 0..<count {
            guard position + 46 <= data.count, u32(position) == 0x02014b50 else { throw damaged }
            let flags = u16(position + 8), method = UInt16(u16(position + 10))
            let compressed = u32(position + 20), size = u32(position + 24)
            let nameLength = u16(position + 28), extraLength = u16(position + 30), commentLength = u16(position + 32), offset = u32(position + 42)
            guard position + 46 + nameLength <= data.count else { throw damaged }
            let nameData = data.subdata(in: (data.startIndex + position + 46)..<(data.startIndex + position + 46 + nameLength))
            let name = String(data: nameData, encoding: .utf8) ?? String(decoding: nameData, as: UTF8.self)
            found.append(Entry(name: name, method: method, compressedSize: compressed, size: size, offset: offset, encrypted: flags & 1 != 0))
            position += 46 + nameLength + extraLength + commentLength
        }
        entries = found
    }

    func extract(_ entry: Entry, limit: Int) throws -> Data {
        func u16(_ at: Int) -> Int { Int(data[data.startIndex + at]) | Int(data[data.startIndex + at + 1]) << 8 }
        let damaged = RadioError.message("The skin ZIP is damaged, encrypted, or unreadable.")
        guard !entry.encrypted, entry.offset + 30 <= data.count else { throw damaged }
        guard entry.size <= limit else { throw RadioError.message("The skin contains an oversized bitmap or file list.") }
        let start = entry.offset + 30 + u16(entry.offset + 26) + u16(entry.offset + 28)
        guard start + entry.compressedSize <= data.count else { throw damaged }
        let raw = data.subdata(in: (data.startIndex + start)..<(data.startIndex + start + entry.compressedSize))
        switch entry.method {
        case 0: return raw
        case 8:
            guard entry.size > 0 else { return Data() }
            var output = Data(count: entry.size)
            let written = output.withUnsafeMutableBytes { out in raw.withUnsafeBytes { input in
                compression_decode_buffer(out.bindMemory(to: UInt8.self).baseAddress!, entry.size, input.bindMemory(to: UInt8.self).baseAddress!, raw.count, nil, COMPRESSION_ZLIB)
            } }
            guard written == entry.size else { throw damaged }
            return output
        default: throw damaged
        }
    }
}
