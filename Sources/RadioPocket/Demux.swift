import Foundation
import AudioToolbox

/// Receives demuxed compressed audio. Calls arrive on the source’s serial queue.
protocol PacketSink: AnyObject {
    func sinkFormat(_ format: AudioStreamBasicDescription, cookie: Data?)
    func sinkPacket(_ packet: AudioPacket)
    func sinkTitle(_ text: String)
    func sinkFailure(_ message: String)
}

protocol Demuxer: AnyObject {
    func feed(_ data: Data)
    func close()
}

// MARK: - MP3 / AAC (ADTS) byte streams through AudioFileStream

final class FileStreamDemuxer: Demuxer {
    static let maxPacket = 16384
    private weak var sink: PacketSink?
    private var parser: AudioFileStreamID?
    private var format = AudioStreamBasicDescription()
    private var reported = false

    init(sink: PacketSink) { self.sink = sink }
    deinit { close() }

    func close() { if let parser { AudioFileStreamClose(parser) }; parser = nil }

    func feed(_ data: Data) {
        guard !data.isEmpty, !reported || parser != nil else { return }
        if parser == nil {
            let info = Unmanaged.passUnretained(self).toOpaque()
            let status = AudioFileStreamOpen(info, { info, stream, property, _ in
                if property == kAudioFileStreamProperty_ReadyToProducePackets { Unmanaged<FileStreamDemuxer>.fromOpaque(info).takeUnretainedValue().ready(stream) }
            }, { info, bytes, count, data, descriptions in
                Unmanaged<FileStreamDemuxer>.fromOpaque(info).takeUnretainedValue().packets(bytes: bytes, count: count, data: data, descriptions: descriptions)
            }, 0, &parser)
            guard status == noErr else { sink?.sinkFailure("Could not initialize the stream decoder (\(status))."); return }
        }
        guard let parser else { return }
        let status = data.withUnsafeBytes { AudioFileStreamParseBytes(parser, UInt32($0.count), $0.baseAddress!, []) }
        if status != noErr { sink?.sinkFailure("This direct stream isn’t supported MP3/AAC audio (\(status)).") }
    }

    private func ready(_ stream: AudioFileStreamID) {
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard !reported, AudioFileStreamGetProperty(stream, kAudioFileStreamProperty_DataFormat, &size, &format) == noErr else {
            if !reported { sink?.sinkFailure("The stream audio format could not be read.") }
            return
        }
        var cookie: Data?
        var cookieSize: UInt32 = 0
        if AudioFileStreamGetPropertyInfo(stream, kAudioFileStreamProperty_MagicCookieData, &cookieSize, nil) == noErr, cookieSize > 0, cookieSize < 65536 {
            var bytes = Data(count: Int(cookieSize))
            let ok = bytes.withUnsafeMutableBytes { AudioFileStreamGetProperty(stream, kAudioFileStreamProperty_MagicCookieData, &cookieSize, $0.baseAddress!) == noErr }
            if ok { cookie = bytes }
        }
        reported = true
        sink?.sinkFormat(format, cookie: cookie)
    }

    private func packets(bytes: UInt32, count: UInt32, data: UnsafeRawPointer, descriptions: UnsafeMutablePointer<AudioStreamPacketDescription>?) {
        guard reported, count > 0 else { return }
        for i in 0..<Int(count) {
            let offset: Int, size: Int
            var frames = format.mFramesPerPacket
            if let descriptions {
                offset = Int(descriptions[i].mStartOffset); size = Int(descriptions[i].mDataByteSize)
                if descriptions[i].mVariableFramesInPacket != 0 { frames = descriptions[i].mVariableFramesInPacket }
            } else { size = Int(bytes / count); offset = i * size }
            guard size > 0, size <= Self.maxPacket, offset >= 0, UInt64(offset) + UInt64(size) <= UInt64(bytes) else {
                sink?.sinkFailure("Invalid or oversized radio packet."); return
            }
            sink?.sinkPacket(AudioPacket(data: Data(bytes: data.advanced(by: offset), count: size), frames: frames == 0 ? 1152 : frames))
        }
    }
}

// MARK: - Ogg Opus

enum OpusInfo {
    /// PCM frames at 48 kHz that one Opus packet decodes to (RFC 6716 §3.1), or 0 when malformed.
    static func frames(in packet: Data) -> UInt32 {
        guard let toc = packet.first else { return 0 }
        let config = Int(toc >> 3)
        let size: UInt32
        switch config {
        case 0...11: size = [480, 960, 1920, 2880][config % 4]
        case 12...15: size = config % 2 == 0 ? 480 : 960
        default: size = [120, 240, 480, 960][config % 4]
        }
        switch toc & 3 {
        case 0: return size
        case 1, 2: return size * 2
        default:
            guard packet.count > 1 else { return 0 }
            return size * UInt32(packet[packet.startIndex + 1] & 0x3F)
        }
    }
    static func title(fromTags packet: Data) -> String? {
        guard packet.count >= 16, packet.prefix(8) == Data("OpusTags".utf8) else { return nil }
        return comments(in: packet, after: 8)
    }
    /// Artist and title from a Vorbis-style comment block (vendor string, then `KEY=value` entries) starting at `offset`.
    static func comments(in packet: Data, after offset: Int) -> String? {
        let bytes = [UInt8](packet)
        func u32(_ at: Int) -> Int? { at + 4 <= bytes.count ? Int(bytes[at]) | Int(bytes[at + 1]) << 8 | Int(bytes[at + 2]) << 16 | Int(bytes[at + 3]) << 24 : nil }
        guard let vendor = u32(offset), var at = Optional(offset + 4 + vendor), let count = u32(at) else { return nil }
        at += 4
        var fields: [String: String] = [:]
        for _ in 0..<min(count, 256) {
            guard let length = u32(at), at + 4 + length <= bytes.count else { break }
            if let text = String(bytes: bytes[(at + 4)..<(at + 4 + length)], encoding: .utf8), let equals = text.firstIndex(of: "=") {
                fields[text[..<equals].uppercased()] = String(text[text.index(after: equals)...])
            }
            at += 4 + length
        }
        let title = fields["TITLE"] ?? "", artist = fields["ARTIST"] ?? ""
        let combined = artist.isEmpty ? title : title.isEmpty ? artist : "\(artist) - \(title)"
        return combined.isEmpty ? nil : String(combined.prefix(512))
    }
}

/// Reads an Ogg byte stream carrying Opus (handled here) or Vorbis (decoded by `VorbisDecoder`); chained streams are followed.
final class OggDemuxer: Demuxer {
    private enum Codec { case none, opus, vorbis }
    private var codec = Codec.none
    private var vorbis: VorbisDecoder?
    private weak var sink: PacketSink?
    private var buffer = Data()
    private var carry = Data()
    private var stage = 0           // 0 expect OpusHead, 1 expect OpusTags, 2 audio
    private var channels: UInt32 = 0
    private var failed = false
    static let maxBuffered = 4_194_304

    init(sink: PacketSink) { self.sink = sink }
    func close() { buffer = Data(); carry = Data(); vorbis?.close(); vorbis = nil }

    func feed(_ data: Data) {
        guard !failed else { return }
        buffer.append(data)
        guard buffer.count < Self.maxBuffered else { fail("The Ogg stream is malformed."); return }
        while !failed, parsePage() {}
    }

    private func fail(_ message: String) { failed = true; sink?.sinkFailure("\u{1}" + message) }

    /// Consumes one complete page from `buffer`. Returns false when more data is needed.
    private func parsePage() -> Bool {
        guard let sync = Self.findCapture(in: buffer) else { buffer = Data(buffer.suffix(3)); return false }
        if sync > 0 { buffer.removeFirst(sync) }
        guard buffer.count >= 27 else { return false }
        let head = [UInt8](buffer.prefix(27 + 255))
        let segments = Int(head[26])
        guard buffer.count >= 27 + segments else { return false }
        let lacing = Array(head[27..<(27 + segments)])
        let payload = lacing.reduce(0) { $0 + Int($1) }
        let total = 27 + segments + payload
        guard buffer.count >= total else { return false }
        let flags = head[5]
        let raw = Data(buffer.prefix(total))
        let body = Data(buffer[buffer.startIndex + 27 + segments ..< buffer.startIndex + total])
        buffer.removeFirst(total)
        if flags & 0x01 == 0 { carry = Data() }            // not a continuation: drop any stale partial packet
        var cursor = 0
        for lace in lacing {
            carry.append(body[body.startIndex + cursor ..< body.startIndex + cursor + Int(lace)]); cursor += Int(lace)
            if lace < 255 { let packet = carry; carry = Data(); handle(packet, startsStream: flags & 0x02 != 0) }
            if failed { return false }
        }
        if codec == .vorbis { vorbis?.feed(raw) }
        return true
    }

    static func findCapture(in data: Data) -> Int? {
        let magic = Data("OggS".utf8)
        return data.range(of: magic).map { data.distance(from: data.startIndex, to: $0.lowerBound) }
    }

    private func handle(_ packet: Data, startsStream: Bool) {
        if packet.isEmpty { return }
        let vorbisHeader = Data([0x01]) + Data("vorbis".utf8)
        if packet.starts(with: vorbisHeader) {
            guard codec != .opus else { fail("The station changed its audio format."); return }
            if let vorbis { vorbis.restart() } else { vorbis = VorbisDecoder(sink: sink!) }
            codec = .vorbis
            return
        }
        if codec == .vorbis {
            if packet.starts(with: Data([0x03]) + Data("vorbis".utf8)), let title = OpusInfo.comments(in: packet, after: 7) { sink?.sinkTitle(title) }
            return
        }
        if packet.starts(with: Data("OpusHead".utf8)) {
            guard packet.count >= 19 else { fail("The Opus stream header is malformed."); return }
            let channelCount = UInt32(packet[packet.startIndex + 9])
            guard (1...2).contains(channelCount), packet[packet.startIndex + 18] == 0 else {
                fail("This Opus stream uses a channel layout RadioPocket can’t play (mono and stereo only)."); return
            }
            if stage == 0 {
                channels = channelCount
                let format = AudioStreamBasicDescription(mSampleRate: 48000, mFormatID: kAudioFormatOpus, mFormatFlags: 0, mBytesPerPacket: 0, mFramesPerPacket: 0,
                                                         mBytesPerFrame: 0, mChannelsPerFrame: channelCount, mBitsPerChannel: 0, mReserved: 0)
                sink?.sinkFormat(format, cookie: nil)
            } else if channelCount != channels { fail("The station changed its audio format.") ; return }
            stage = 1; codec = .opus
        } else if stage == 0 {
            fail("This Ogg stream isn’t Opus or Vorbis audio. RadioPocket plays Opus, Vorbis, MP3, AAC and HLS.")
        } else if stage == 1 {
            if let title = OpusInfo.title(fromTags: packet) { sink?.sinkTitle(title); stage = 2 }
            else { stage = 2; handleAudio(packet) }
        } else { handleAudio(packet) }
    }
    private func handleAudio(_ packet: Data) {
        let frames = OpusInfo.frames(in: packet)
        guard frames > 0 else { return }
        sink?.sinkPacket(AudioPacket(data: packet, frames: frames))
        if stage == 2 { stage = 3 }
    }
}

// MARK: - MPEG transport stream and packed audio segments (HLS)

enum HLSSegmentKind { case transport, packedAudio, fragmentedMP4, unknown }

enum TSDemuxer {
    static func kind(of data: Data) -> HLSSegmentKind {
        guard let first = data.first else { return .unknown }
        if first == 0x47 { return .transport }
        if data.starts(with: Data("ID3".utf8)) || first == 0xFF { return .packedAudio }
        if data.count > 8, ["ftyp", "styp", "moof"].contains(String(decoding: data[data.startIndex + 4 ..< data.startIndex + 8], as: UTF8.self)) { return .fragmentedMP4 }
        return .unknown
    }

    /// Removes a leading ID3v2 tag from packed audio and returns the title it carries, if any.
    static func stripID3(_ data: Data) -> (audio: Data, title: String?) {
        guard data.count >= 10, data.starts(with: Data("ID3".utf8)) else { return (data, nil) }
        let b = [UInt8](data.prefix(10))
        let size = Int(b[6] & 0x7F) << 21 | Int(b[7] & 0x7F) << 14 | Int(b[8] & 0x7F) << 7 | Int(b[9] & 0x7F)
        guard data.count >= 10 + size else { return (data, nil) }
        return (Data(data.dropFirst(10 + size)), id3Title(Data(data[data.startIndex + 10 ..< data.startIndex + 10 + size])))
    }

    /// Minimal ID3v2.3/2.4 reader for TIT2 (+ TPE1) text frames.
    static func id3Title(_ tag: Data) -> String? {
        let bytes = [UInt8](tag)
        var at = 0
        var fields: [String: String] = [:]
        while at + 10 <= bytes.count, bytes[at] != 0 {
            let id = String(decoding: bytes[at..<(at + 4)], as: UTF8.self)
            let size = Int(bytes[at + 4]) << 24 | Int(bytes[at + 5]) << 16 | Int(bytes[at + 6]) << 8 | Int(bytes[at + 7])
            guard size > 0, at + 10 + size <= bytes.count else { break }
            if id == "TIT2" || id == "TPE1", size > 1 {
                let encoding = bytes[at + 10], text = Array(bytes[(at + 11)..<(at + 10 + size)])
                let string: String? = encoding == 1 || encoding == 2 ? String(bytes: text, encoding: .utf16) : encoding == 3 ? String(bytes: text, encoding: .utf8) : String(bytes: text, encoding: .isoLatin1)
                if let string { fields[id] = string.trimmingCharacters(in: CharacterSet(charactersIn: "\0 ")) }
            }
            at += 10 + size
        }
        let title = fields["TIT2"] ?? "", artist = fields["TPE1"] ?? ""
        let combined = artist.isEmpty ? title : title.isEmpty ? artist : "\(artist) - \(title)"
        return combined.isEmpty ? nil : String(combined.prefix(512))
    }

    /// Extracts the elementary audio stream (ADTS AAC or MPEG audio) from a transport-stream segment.
    /// Returns nil when no supported audio stream exists.
    static func audio(from segment: Data) -> (audio: Data, title: String?)? {
        let bytes = [UInt8](segment)
        guard bytes.count >= 188 else { return nil }
        var start = 0
        while start + 188 < bytes.count, !(bytes[start] == 0x47 && bytes[start + 188] == 0x47) { start += 1 }
        var pmtPID: Int?, audioPID: Int?, metadataPID: Int?
        var output = Data(), metadata = Data()
        var title: String?
        var index = start
        while index + 188 <= bytes.count {
            defer { index += 188 }
            guard bytes[index] == 0x47 else { continue }
            let pid = Int(bytes[index + 1] & 0x1F) << 8 | Int(bytes[index + 2])
            let unitStart = bytes[index + 1] & 0x40 != 0
            let control = (bytes[index + 3] >> 4) & 3
            guard control & 1 == 1 else { continue }
            var payload = index + 4
            if control & 2 != 0 { payload += 1 + Int(bytes[index + 4]) }
            guard payload < index + 188 else { continue }
            let body = bytes[payload..<(index + 188)]
            if pid == 0, unitStart, pmtPID == nil {
                let table = Array(body.dropFirst(1 + Int(body.first ?? 0)))
                guard table.count >= 12 else { continue }
                let sectionEnd = min(table.count, 3 + (Int(table[1] & 0x0F) << 8 | Int(table[2])))
                var at = 8
                while at + 4 <= sectionEnd - 4 {
                    let program = Int(table[at]) << 8 | Int(table[at + 1])
                    if program != 0 { pmtPID = Int(table[at + 2] & 0x1F) << 8 | Int(table[at + 3]); break }
                    at += 4
                }
            } else if pid == pmtPID, unitStart, audioPID == nil {
                let table = Array(body.dropFirst(1 + Int(body.first ?? 0)))
                guard table.count > 12 else { continue }
                let sectionEnd = min(table.count, 3 + (Int(table[1] & 0x0F) << 8 | Int(table[2])) - 4)
                var at = 12 + (Int(table[10] & 0x0F) << 8 | Int(table[11]))
                while at + 5 <= sectionEnd {
                    let type = table[at], esPID = Int(table[at + 1] & 0x1F) << 8 | Int(table[at + 2])
                    if audioPID == nil, [0x0F, 0x03, 0x04].contains(type) { audioPID = esPID }
                    if type == 0x15 { metadataPID = esPID }
                    at += 5 + (Int(table[at + 3] & 0x0F) << 8 | Int(table[at + 4]))
                }
            } else if pid == audioPID || pid == metadataPID {
                var data = Data(body)
                if unitStart {
                    guard data.count >= 9, data[data.startIndex] == 0, data[data.startIndex + 1] == 0, data[data.startIndex + 2] == 1 else { continue }
                    let skip = 9 + Int(data[data.startIndex + 8])
                    guard data.count >= skip else { continue }
                    data = Data(data.dropFirst(skip))
                    if pid == metadataPID { if !metadata.isEmpty, let found = id3Title(Data(metadata.dropFirst(10))) { title = found }; metadata = Data() }
                }
                if pid == audioPID { output.append(data) } else { metadata.append(data) }
            }
        }
        if !metadata.isEmpty, let found = id3Title(Data(metadata.dropFirst(10))) { title = found }
        guard audioPID != nil, !output.isEmpty else { return nil }
        return (output, title)
    }
}

typealias OggOpusDemuxer = OggDemuxer
