import AppKit
import AVFoundation
import Network
import CEQ

final class RadioEngine: NSObject, AVPlayerItemMetadataOutputPushDelegate {
    enum Status: String { case stopped = "STOPPED", connecting = "CONNECTING", playing = "LIVE", paused = "PAUSED", failed = "OFFLINE" }
    let player = AVPlayer()
    let equalizer = Equalizer()
    private(set) var status: Status = .stopped
    private(set) var station: Station?
    private(set) var title = "OPEN A STREAM TO BEGIN"
    private(set) var detail = "DIRECT INTERNET RADIO"
    private(set) var elapsed = 0
    /// Seconds left on the sleep timer, shown on the status line while it runs.
    var sleepRemaining: Int?
    /// Evens out loud and quiet stations. Applies to every stream RadioPocket decodes itself.
    var leveling = false { didSet { stream?.setLeveling(leveling); refreshEQStatus() } }
    /// Left/right balance, -1 to 1.
    private(set) var balance: Float = 0
    var changed: (() -> Void)?
    /// Called once when automatic reconnection gives up (or the stream can never play), so the app can offer alternatives.
    var onGiveUp: ((Station, String) -> Void)?
    static let maxRetries = 8
    private let monitor = NWPathMonitor()
    private var networkAvailable = true
    private var interfaceType: NWInterface.InterfaceType?
    private var resumeWhenOnline = false
    private var paused = false
    private var streamLost = false
    private var playingSince: Date?
    private var itemObservation: NSKeyValueObservation?
    private var playbackObservation: NSKeyValueObservation?
    private var notifications: [NSObjectProtocol] = []
    private var task: Task<Void, Never>?
    private var stream: RadioStream?
    private var timeout: DispatchWorkItem?
    private var retry: DispatchWorkItem?
    private var clock: Timer?
    private var generation = UUID()
    private var retries = 0
    private var wantsPlayback = false

    override init() {
        super.init()
        player.automaticallyWaitsToMinimizeStalling = true
        playbackObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.playbackChanged() }
        }
        monitor.pathUpdateHandler = { [weak self] path in DispatchQueue.main.async { self?.pathChanged(path) } }
        monitor.start(queue: DispatchQueue(label: "radiopocket.network", qos: .utility))
        notifications.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in self?.didWake() })
    }
    deinit { monitor.cancel() }

    // MARK: Network and sleep

    private func pathChanged(_ path: NWPath) {
        let online = path.status == .satisfied
        let type = [NWInterface.InterfaceType.wifi, .wiredEthernet, .cellular, .other].first { path.usesInterfaceType($0) }
        let wasOnline = networkAvailable, previous = interfaceType
        networkAvailable = online
        if online { interfaceType = type }
        guard online else { return }
        if !wasOnline {
            if resumeWhenOnline || (wantsPlayback && status == .connecting) { reconnect("NETWORK BACK • RECONNECTING") }
        } else if let type, let previous, type != previous, wantsPlayback, status == .playing || status == .connecting, stream != nil || status == .connecting {
            reconnect("NETWORK CHANGED • RECONNECTING")
        }
    }

    /// Sleep kills TCP connections without telling anyone; start over once the network has had a moment to return.
    private func didWake() {
        guard station != nil else { return }
        if paused { streamLost = true; return }
        guard wantsPlayback || resumeWhenOnline else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.wantsPlayback || self.resumeWhenOnline else { return }
            self.reconnect("WOKE FROM SLEEP • RECONNECTING")
        }
    }

    private func reconnect(_ message: String) {
        guard station != nil else { return }
        retries = 0; resumeWhenOnline = false; paused = false; streamLost = false
        connect()
        detail = message
        changed?()
    }

    // MARK: Time shift

    /// How far behind the live edge playback is, in seconds.
    var delay: Double { stream?.delay ?? 0 }
    var canTimeShift: Bool { stream != nil && (status == .playing || status == .paused) }
    func seek(by seconds: Double) {
        guard canTimeShift else { return }
        stream?.seek(by: seconds)
        refreshEQStatus(); changed?()
    }
    func goLive() {
        guard canTimeShift else { return }
        stream?.goLive()
        refreshEQStatus(); changed?()
    }
    private func liveDetail() -> String {
        let volume = Int((player.volume * 100).rounded())
        if !equalizer.available && equalizer.settings.enabled { return "LIVE • EQ UNAVAILABLE FOR THIS STREAM" }
        let behind = Int(delay.rounded())
        let sleep = sleepRemaining.map { String(format: " • SLEEP %d:%02d", $0 / 60, $0 % 60) } ?? ""
        if behind >= 2 { return String(format: "DELAYED -%d:%02d • L: LIVE • %d%%", behind / 60, behind % 60, volume) + sleep }
        return "LIVE STREAM • \(volume)% VOLUME" + sleep
    }

    func play(_ station: Station) {
        self.station = station
        retries = 0
        elapsed = 0
        paused = false; streamLost = false; resumeWhenOnline = false
        connect()
    }

    private func connect() {
        guard let station else { return }
        clearConnection()
        wantsPlayback = true
        status = .connecting
        title = station.name
        detail = retries == 0 ? "CONNECTING TO STATION" : "RECONNECTING \(retries)/\(Self.maxRetries)"
        changed?()
        let token = generation
        task = Task { @MainActor [weak self] in
            do {
                let source = try StreamAddress.parse(station.address)
                let url = try await StreamAddress.resolve(source)
                try Task.checkCancellation()
                guard let self, self.generation == token else { return }
                self.install(url, token: token)
            } catch {
                guard let self, self.generation == token, !(error is CancellationError) else { return }
                self.fail(error.localizedDescription)
            }
        }
        armTimeout(token: token)
    }

    private func install(_ url: URL, token: UUID) {
        let direct = RadioStream(volume: player.volume, balance: balance, leveling: leveling)
        stream = direct
        equalizer.bind(direct.dsp)
        direct.playing = { [weak self] in
            guard let self, self.generation == token else { return }
            self.beginPlaying()
        }
        direct.metadata = { [weak self] value in
            guard let self, self.generation == token else { return }
            self.title = value; self.changed?()
        }
        direct.failed = { [weak self] message in
            guard let self, self.generation == token else { return }
            if message.contains("isn’t supported MP3/AAC") || message.hasPrefix(HLSSource.unsupportedPrefix) {
                self.stream?.stop(); self.stream = nil; self.equalizer.disconnect()
                self.installAVPlayer(url, token: token)
            } else if message.hasPrefix(RadioStream.permanentMarker) { self.giveUp(String(message.dropFirst(RadioStream.permanentMarker.count))) }
            else { self.fail(message) }
        }
        direct.start(url)
    }

    /// What the connection is doing now, for the display and the station-info window. Nil for AVPlayer fallback streams.
    struct StreamInfo {
        var codec: String, sampleRate: Double, channels: Int
        var kbps: Int?
        var bufferedSeconds: Double, delay: Double
        var levelDb: Double
    }
    var streamInfo: StreamInfo? {
        guard let stream, let format = stream.format else { return nil }
        return StreamInfo(codec: format.codec, sampleRate: format.rate, channels: format.channels, kbps: stream.bitrate(),
                          bufferedSeconds: stream.rewindable, delay: stream.delay, levelDb: leveling ? stream.levelGain : 0)
    }
    /// True when playback runs through AVPlayer, which has no EQ, leveler or buffer to report.
    var usesFallbackPlayer: Bool { stream == nil && player.currentItem != nil }

    /// Newest mono post-EQ samples for the visualizer, or nil when nothing is playing or the stream
    /// is decoded by AVPlayer (HLS), whose audio macOS does not expose to a processing tap.
    /// True while playing a direct stream whose decoded audio the visualizer can read.
    var hasVisSignal: Bool { status == .playing && stream != nil }
    func readVisSamples(_ out: UnsafeMutablePointer<Float>, count: Int) -> Double? {
        guard status == .playing else { return nil }
        if let stream { _ = rp_vis_read(stream.dsp, out, UInt32(count)); return rp_eq_rate(stream.dsp) }
        return nil
    }

    private func installAVPlayer(_ url: URL, token: UUID) {
        let item = AVPlayerItem(url: url)
        item.preferredForwardBufferDuration = 3
        let metadata = AVPlayerItemMetadataOutput(identifiers: nil)
        metadata.setDelegate(self, queue: .main)
        item.add(metadata)
        itemObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            let error = item.error?.localizedDescription
            let failed = item.status == .failed
            DispatchQueue.main.async {
                guard let self, self.generation == token else { return }
                if failed { self.fail(error ?? "This stream format is not supported by macOS.") }
                else if item.status == .readyToPlay { self.player.play() }
            }
        }
        for name in [AVPlayerItem.failedToPlayToEndTimeNotification, AVPlayerItem.didPlayToEndTimeNotification] {
            notifications.append(NotificationCenter.default.addObserver(forName: name, object: item, queue: .main) { [weak self] _ in
                guard let self, self.generation == token else { return }
                self.fail("The station closed the connection.")
            })
        }
        player.replaceCurrentItem(with: item)
    }

    private func playbackChanged() {
        guard wantsPlayback, player.currentItem != nil else { return }
        switch player.timeControlStatus {
        case .playing:
            beginPlaying()
        case .waitingToPlayAtSpecifiedRate:
            clock?.invalidate(); clock = nil
            status = .connecting
            detail = "BUFFERING"
            armTimeout(token: generation)
        case .paused: break
        @unknown default: break
        }
        changed?()
    }

    private func beginPlaying() {
        timeout?.cancel(); timeout = nil
        status = .playing
        paused = false
        if playingSince == nil { playingSince = Date() }
        detail = liveDetail()
        if clock == nil {
            clock = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                guard let self else { return }
                if self.status == .paused { self.detail = self.pausedDetail(); self.changed?(); return }
                self.elapsed += 1
                // A connection that went quiet without closing (Wi-Fi roam, dead NAT entry) never reports an error.
                if let stream = self.stream, Date().timeIntervalSince(stream.lastActivity) > 20 { self.fail("The stream stopped delivering audio."); return }
                if let since = self.playingSince, Date().timeIntervalSince(since) > 30 { self.retries = 0 }
                self.refreshEQStatus()
                self.changed?()
            }
            clock?.tolerance = 0.2
        }
        changed?()
    }

    func refreshEQStatus() {
        guard status == .playing else {
            if status == .paused, stream != nil, !streamLost { detail = pausedDetail() ; changed?() }
            return
        }
        detail = liveDetail()
        changed?()
    }

    private func armTimeout(token: UUID) {
        guard timeout == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.generation == token else { return }
            self.fail("The station did not respond. Check the stream URL or try again.")
        }
        timeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 25, execute: work)
    }

    private func fail(_ message: String) {
        guard wantsPlayback else { return }
        clearConnection()
        if paused {
            // The server dropped a paused stream; there is nothing to resume, so Play reconnects to live.
            streamLost = true; status = .paused
            detail = "PAUSED • STREAM ENDED, PLAY RECONNECTS"
            changed?(); return
        }
        playingSince = nil
        guard networkAvailable else {
            status = .connecting; resumeWhenOnline = true
            detail = "WAITING FOR NETWORK"
            changed?(); return
        }
        guard retries < Self.maxRetries else { giveUp(message, retryOnNetwork: true); return }
        retries += 1
        status = .connecting
        detail = "RETRY \(retries)/\(Self.maxRetries) • \(message)"
        let token = generation
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.generation == token else { return }
            self.connect()
        }
        retry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + min(30, Double(1 << min(retries, 5))), execute: work)
        changed?()
    }

    private func giveUp(_ message: String, retryOnNetwork: Bool = false) {
        clearConnection()
        wantsPlayback = false
        status = .failed
        detail = message
        resumeWhenOnline = retryOnNetwork
        changed?()
        if let station { onGiveUp?(station, message) }
    }

    private func pausedDetail() -> String {
        let behind = Int(delay.rounded()) + 0
        return behind >= 2 ? String(format: "PAUSED • -%d:%02d BEHIND LIVE", behind / 60, behind % 60) : "PAUSED • PLAY RESUMES"
    }

    /// With a direct stream, pause keeps the connection and buffers what the station sends (up to five minutes),
    /// so Play continues exactly where you stopped. AVPlayer streams still disconnect and return to live.
    func pause() {
        if let stream, status == .playing {
            stream.pause(); paused = true
            status = .paused
            detail = pausedDetail()
            changed?(); return
        }
        wantsPlayback = false; paused = false
        clearConnection()
        status = .paused
        detail = "PAUSED • PLAY RETURNS TO LIVE"
        changed?()
    }

    func stop() {
        wantsPlayback = false; paused = false; streamLost = false; resumeWhenOnline = false
        clearConnection()
        status = .stopped
        elapsed = 0
        detail = "DIRECT INTERNET RADIO"
        changed?()
    }

    func resume() {
        guard station != nil else { return }
        if paused, let stream, !streamLost, Date().timeIntervalSince(stream.lastActivity) < 20 {
            paused = false
            stream.resume()
            beginPlaying(); return
        }
        retries = 0; elapsed = 0
        paused = false; streamLost = false; resumeWhenOnline = false
        connect()
    }

    func setVolume(_ value: Float) {
        player.volume = min(1, max(0, value))
        stream?.setVolume(player.volume)
        refreshEQStatus()
        changed?()
    }

    func setBalance(_ value: Float) {
        balance = min(1, max(-1, value))
        stream?.setBalance(balance)
        changed?()
    }

    private func clearConnection() {
        generation = UUID()
        equalizer.disconnect()
        stream?.stop(); stream = nil
        task?.cancel(); task = nil
        timeout?.cancel(); timeout = nil
        retry?.cancel(); retry = nil
        clock?.invalidate(); clock = nil
        playingSince = nil
        itemObservation = nil
        notifications.forEach(NotificationCenter.default.removeObserver)
        notifications.removeAll()
        player.pause()
        player.replaceCurrentItem(with: nil)
        equalizer.disconnect()
    }

    func metadataOutput(_ output: AVPlayerItemMetadataOutput, didOutputTimedMetadataGroups groups: [AVTimedMetadataGroup], from track: AVPlayerItemTrack?) {
        guard wantsPlayback else { return }
        let token = generation
        let items = groups.flatMap(\.items).filter {
            $0.commonKey == .commonKeyTitle || $0.identifier == .icyMetadataStreamTitle
        }
        Task { @MainActor [weak self] in
            for item in items {
                if let value = try? await item.load(.stringValue), !value.isEmpty {
                    guard let self, self.generation == token, self.wantsPlayback else { return }
                    self.title = String(value.prefix(512))
                    self.changed?()
                    break
                }
            }
        }
    }
}
