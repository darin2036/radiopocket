import Foundation
import AudioToolbox
import CEQ

/// One live radio connection: source (HTTP/ICY or HLS) → demuxer (MP3/AAC, Ogg Opus) → time-shift ring → AudioQueue.
/// The same pipeline serves every stream type, so the equalizer, visualizer, pause and rewind work on all of them.
final class RadioStream: NSObject, PacketSink, @unchecked Sendable {
    /// Failure messages starting with this marker can never succeed on retry (unsupported codec, bad layout).
    static let permanentMarker = "\u{1}"
    let dsp = rp_eq_create()!
    var playing: (() -> Void)?
    var failed: ((String) -> Void)?
    var metadata: ((String) -> Void)?
    private let ring = PacketRing()
    private let lock = NSLock()
    private var output: AudioOutput?
    private var source: StreamSource?
    private var demuxer: Demuxer?
    private var address: URL?
    private var stopped = false
    private var announced = false
    private var baselineDelay = 0.0
    private(set) var isPaused = false
    private var received = 0
    private var formatInfo: (codec: String, rate: Double, channels: Int)?
    private var rateMark: (date: Date, bytes: Int, kbps: Int)?

    init(volume: Float, leveling: Bool = false) {
        super.init()
        rp_eq_volume(dsp, volume)
        rp_level_set(dsp, leveling ? 1 : 0)
    }
    deinit { rp_eq_destroy(dsp) }

    func setVolume(_ value: Float) { rp_eq_volume(dsp, value) }
    func setLeveling(_ on: Bool) { rp_level_set(dsp, on ? 1 : 0) }
    /// Gain in dB the loudness leveler is applying right now (0 when off).
    var levelGain: Double { rp_level_db(dsp) }

    /// Codec, sample rate and channel count of the decoded stream, once known.
    var format: (codec: String, rate: Double, channels: Int)? { lock.lock(); defer { lock.unlock() }; return formatInfo }
    /// Compressed bytes received from the station so far.
    var bytesReceived: Int { lock.lock(); defer { lock.unlock() }; return received }
    /// Average download rate in kb/s, measured over at least two seconds. Nil until that much has arrived.
    func bitrate() -> Int? {
        lock.lock(); defer { lock.unlock() }
        let now = Date()
        guard let mark = rateMark else { rateMark = (now, received, 0); return nil }
        let elapsed = now.timeIntervalSince(mark.date)
        guard elapsed >= 2 else { return mark.kbps > 0 ? mark.kbps : nil }
        let kbps = Int((Double(received - mark.bytes) * 8 / 1000 / elapsed).rounded())
        rateMark = (now, received, kbps)
        return kbps > 0 ? kbps : nil
    }
    private func count(_ data: Data) { lock.lock(); received += data.count; lock.unlock() }

    // MARK: Control

    func start(_ url: URL) {
        address = url
        if ["m3u8", "m3u"].contains(url.pathExtension.lowercased()) { startHLS(url) } else { startHTTP(url) }
    }

    private func startHTTP(_ url: URL) {
        let http = HTTPSource(url: url)
        http.onResponse = { [weak self, weak http] type in
            guard let self, let http, type.contains("mpegurl") else { return }
            http.stop(); self.startHLS(url)       // a playlist behind a non-.m3u8 address
        }
        http.onData = { [weak self] data in self?.receive(data, from: url) }
        http.onTitle = { [weak self] title in self?.sinkTitle(title) }
        http.onFailure = { [weak self] message in self?.sinkFailure(message) }
        lock.lock(); source = http; lock.unlock()
        http.start()
    }

    private func startHLS(_ url: URL) {
        let hls = HLSSource(url: url)
        hls.onAudio = { [weak self] data in
            guard let self else { return }
            self.count(data)
            if self.demuxer == nil { self.demuxer = FileStreamDemuxer(sink: self) }
            self.demuxer?.feed(data)
        }
        hls.onTitle = { [weak self] title in self?.sinkTitle(title) }
        hls.onFailure = { [weak self] message in self?.sinkFailure(message) }
        lock.lock(); source = hls; lock.unlock()
        hls.start()
    }

    /// Picks the demuxer from the first bytes (a Content-Type can lie; the container’s magic cannot).
    private func receive(_ data: Data, from url: URL) {
        count(data)
        if demuxer == nil {
            if data.starts(with: Data("OggS".utf8)) { demuxer = OggDemuxer(sink: self) }
            else if data.starts(with: Data("#EXTM3U".utf8)) {
                source?.stop(); startHLS(url); return
            } else { demuxer = FileStreamDemuxer(sink: self) }
        }
        demuxer?.feed(data)
    }

    func pause() {
        isPaused = true
        lock.lock(); let output = self.output; lock.unlock()
        output?.pause()
    }
    func resume() {
        isPaused = false
        lock.lock(); let output = self.output; lock.unlock()
        output?.resume()
    }
    /// Moves playback by `seconds` (negative = back). Returns the new delay behind live.
    @discardableResult func seek(by seconds: Double) -> Double {
        lock.lock(); let output = self.output; lock.unlock()
        let behind = ring.seek(by: seconds, alreadyQueued: output?.queuedSeconds ?? 0)
        output?.flush()
        return behind
    }
    func goLive() {
        lock.lock(); let output = self.output; lock.unlock()
        ring.goLive(); output?.flush()
    }
    func stop() {
        lock.lock(); stopped = true; let source = self.source, output = self.output, demuxer = self.demuxer
        self.source = nil; self.output = nil; self.demuxer = nil; lock.unlock()
        source?.stop(); demuxer?.close()
        if let output { output.stop() } else { ring.close() }
    }

    // MARK: State for the UI

    /// When the last network or segment data arrived; the engine uses it to spot a silently stalled connection.
    var lastActivity: Date { lock.lock(); defer { lock.unlock() }; return source?.lastActivity ?? Date() }
    /// How far behind the live edge playback is, beyond the stream’s own startup latency.
    var delay: Double {
        lock.lock(); let output = self.output; lock.unlock()
        return max(0, ring.secondsBehindLive + (output?.queuedSeconds ?? 0) - baselineDelay)
    }
    /// Seconds of history available to rewind into.
    var rewindable: Double { ring.retainedSeconds }

    // MARK: PacketSink

    func sinkFormat(_ format: AudioStreamBasicDescription, cookie: Data?) {
        lock.lock(); defer { lock.unlock() }
        guard output == nil, !stopped else { return }
        let codec: String
        switch format.mFormatID {
        case kAudioFormatMPEGLayer3: codec = "MP3"
        case kAudioFormatMPEG4AAC, kAudioFormatMPEG4AAC_HE, kAudioFormatMPEG4AAC_HE_V2: codec = "AAC"
        case kAudioFormatOpus: codec = "OPUS"
        case kAudioFormatLinearPCM: codec = "VORBIS"      // the only PCM source is the bundled Vorbis decoder
        default: codec = "AUDIO"
        }
        formatInfo = (codec, format.mSampleRate, Int(format.mChannelsPerFrame))
        let out = AudioOutput(dsp: dsp, ring: ring)
        out.playing = { [weak self] in
            guard let self else { return }
            if !self.announced {
                self.announced = true
                self.lock.lock(); let out = self.output; self.lock.unlock()
                self.baselineDelay = self.ring.secondsBehindLive + (out?.queuedSeconds ?? 0)
                // Servers often burst a few seconds of audio on connect; settle the baseline once that has arrived.
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                    guard let self, !self.isPaused else { return }
                    self.lock.lock(); let out = self.output; self.lock.unlock()
                    self.baselineDelay = self.ring.secondsBehindLive + (out?.queuedSeconds ?? 0)
                }
            }
            self.playing?()
        }
        out.failed = { [weak self] message in self?.failed?(message) }
        output = out
        out.configure(format, cookie: cookie)
    }
    func sinkPacket(_ packet: AudioPacket) { ring.append(packet) }
    func sinkTitle(_ text: String) { DispatchQueue.main.async { [weak self] in self?.metadata?(text) } }
    func sinkFailure(_ message: String) {
        lock.lock(); let done = stopped; lock.unlock()
        guard !done else { return }
        DispatchQueue.main.async { [weak self] in self?.failed?(message) }
    }
}
