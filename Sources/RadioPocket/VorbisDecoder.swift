import Foundation
import AudioToolbox
import CVorbis

/// Decodes an Ogg Vorbis logical stream with stb_vorbis (push-data API) into 16-bit PCM packets.
/// macOS has no Vorbis codec, so decoded audio, not compressed packets, goes into the time-shift ring.
final class VorbisDecoder {
    private weak var sink: PacketSink?
    private var decoder: OpaquePointer?
    private var pending = Data()
    private var channels: UInt32 = 0
    private var rate: Double = 0
    private var failed = false
    private static let chunkFrames = 2048
    private static let maxPending = 2_097_152

    init(sink: PacketSink) { self.sink = sink }
    deinit { closeDecoder() }

    private func closeDecoder() { if let decoder { stb_vorbis_close(decoder) }; decoder = nil }

    /// A new logical stream began (a chained Ogg stream, typically a title change): start over with its headers.
    func restart() { closeDecoder(); pending = Data() }
    func close() { closeDecoder(); pending = Data(); failed = true }

    private func fail(_ message: String) { failed = true; closeDecoder(); sink?.sinkFailure("\u{1}" + message) }

    /// Feeds whole Ogg pages exactly as received (header pages first).
    func feed(_ pages: Data) {
        guard !failed else { return }
        pending.append(pages)
        guard pending.count < Self.maxPending else { fail("The Vorbis stream is malformed."); return }
        if decoder == nil, !open() { return }
        decode()
    }

    /// Tries to open the decoder from the accumulated header pages. False while more data is needed.
    private func open() -> Bool {
        var used: Int32 = 0, error: Int32 = 0
        let opened = pending.withUnsafeBytes { raw in
            stb_vorbis_open_pushdata(raw.bindMemory(to: UInt8.self).baseAddress, Int32(raw.count), &used, &error, nil)
        }
        guard let opened else {
            if error != Int32(VORBIS_need_more_data.rawValue) { fail("This Vorbis stream couldn’t be decoded (error \(error)).") }
            return false
        }
        decoder = opened
        pending.removeFirst(Int(used))
        let info = stb_vorbis_get_info(opened)
        guard (1...2).contains(info.channels), info.sample_rate >= 8000, info.sample_rate <= 192_000 else {
            fail("This Vorbis stream uses a channel layout or sample rate RadioPocket can’t play."); return false
        }
        if channels == 0 {
            channels = UInt32(info.channels); rate = Double(info.sample_rate)
            let bytes = 2 * channels
            sink?.sinkFormat(AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked, mBytesPerPacket: bytes, mFramesPerPacket: 1,
                mBytesPerFrame: bytes, mChannelsPerFrame: channels, mBitsPerChannel: 16, mReserved: 0), cookie: nil)
        } else if channels != UInt32(info.channels) || rate != Double(info.sample_rate) {
            fail("The station changed its audio format."); return false
        }
        return true
    }

    private func decode() {
        guard let decoder else { return }
        while !failed, !pending.isEmpty {
            var outputChannels: Int32 = 0, samples: Int32 = 0
            var output: UnsafeMutablePointer<UnsafeMutablePointer<Float>?>?
            let used = pending.withUnsafeBytes { raw in
                stb_vorbis_decode_frame_pushdata(decoder, raw.bindMemory(to: UInt8.self).baseAddress, Int32(raw.count), &outputChannels, &output, &samples)
            }
            if used <= 0 {
                // Needs more data, or hit damage: wait for the next page rather than stalling on bad bytes.
                if stb_vorbis_get_error(decoder) != Int32(VORBIS_need_more_data.rawValue) { pending = Data() }
                return
            }
            pending.removeFirst(Int(used))
            guard samples > 0, let output, outputChannels == Int32(channels) else { continue }
            emit(output, frames: Int(samples))
        }
    }

    private func emit(_ output: UnsafeMutablePointer<UnsafeMutablePointer<Float>?>, frames: Int) {
        let count = Int(channels)
        var start = 0
        while start < frames {
            let n = min(Self.chunkFrames, frames - start)
            var pcm = [Int16](repeating: 0, count: n * count)
            for c in 0..<count {
                guard let channel = output[c] else { return }
                for i in 0..<n {
                    let value = channel[start + i] * 32767
                    pcm[i * count + c] = Int16(max(-32768, min(32767, value.isFinite ? value : 0)))
                }
            }
            sink?.sinkPacket(AudioPacket(data: pcm.withUnsafeBytes { Data($0) }, frames: UInt32(n)))
            start += n
        }
    }
}
