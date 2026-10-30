import AppKit

/// What RadioPocket knows about the station that is playing: the live connection (format, measured bitrate,
/// time-shift buffer, leveler) and, on request, the directory's record for it.
final class StationInfoController: NSWindowController {
    private let engine: RadioEngine
    private let directory: RadioDirectory
    private var rows: [(String, NSTextField)] = []
    private var timer: Timer?
    private var listing: RadioListing?
    private var lookupMessage: String?
    private var lookupTask: Task<Void, Never>?
    private let lookup = ClassicButton(title: "Look Up Details", target: nil, action: nil)
    private let homepage = ClassicButton(title: "Open Homepage", target: nil, action: nil)
    private static let labels = ["Station", "Stream", "Now playing", "Status", "Format", "Bitrate", "Buffer", "Leveling", "Country", "Genre", "Directory",
                                  "HTTP", "Content type", "Server", "ICY", "First bytes", "Final URL"]
    /// A library row being inspected instead of the station that is playing.
    private var inspected: RadioListing?
    private var probe: StreamReply.Result?
    private var probeTask: Task<Void, Never>?
    private static let height = CGFloat(30 + labels.count * 22 + 70)

    init(engine: RadioEngine, directory: RadioDirectory) {
        self.engine = engine; self.directory = directory
        let window = PlayerWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: Self.height), styleMask: [.borderless], backing: .buffered, defer: false)
        window.title = "Station Info"
        window.isReleasedWhenClosed = false; window.hasShadow = true; window.appearance = NSAppearance(named: .darkAqua)
        super.init(window: window)
        let root = ClassicChrome(frame: NSRect(x: 0, y: 0, width: 460, height: Self.height)); root.title = "STATION INFO"
        window.contentView = root
        let close = ClassicWindowButton(title: "×", target: self, action: #selector(dismiss))
        close.frame = NSRect(x: 448, y: 3, width: 9, height: 9); close.isBordered = false; close.setAccessibilityLabel("Close"); root.addSubview(close)
        for (i, name) in Self.labels.enumerated() {
            let key = NSTextField(labelWithString: name.uppercased()); key.font = .monospacedSystemFont(ofSize: 9, weight: .semibold); key.textColor = ClassicUI.dim
            key.frame = NSRect(x: 14, y: CGFloat(30 + i * 22) + 3, width: 84, height: 16); root.addSubview(key)
            let value = NSTextField(labelWithString: ""); value.font = ClassicUI.font; value.textColor = i < 4 ? ClassicUI.green : ClassicUI.text
            value.lineBreakMode = .byTruncatingMiddle; value.isSelectable = true
            value.frame = NSRect(x: 100, y: CGFloat(30 + i * 22) + 2, width: 346, height: 18); root.addSubview(value)
            rows.append((name, value))
        }
        for (button, title, selector, x) in [(lookup, "Look Up Details", #selector(lookUp), 14.0), (homepage, "Open Homepage", #selector(openHomepage), 134.0)] {
            button.title = title; button.target = self; button.action = selector; button.isBordered = false
            button.frame = NSRect(x: x, y: Self.height - 46, width: 112, height: 23); root.addSubview(button)
        }
        let copy = ClassicButton(title: "Copy URL", target: self, action: #selector(copyURL))
        copy.isBordered = false; copy.frame = NSRect(x: 254, y: Self.height - 46, width: 82, height: 23); root.addSubview(copy)
        let done = ClassicButton(title: "Close", target: self, action: #selector(dismiss))
        done.isBordered = false; done.keyEquivalent = "\u{1b}"; done.frame = NSRect(x: 364, y: Self.height - 46, width: 82, height: 23); root.addSubview(done)
    }
    required init?(coder: NSCoder) { fatalError() }

    func present(over player: NSWindow?) {
        if window?.isVisible != true, let player { window?.setFrameTopLeftPoint(NSPoint(x: player.frame.minX, y: player.frame.minY - 8)) }
        inspected = nil; listing = nil; lookupMessage = nil; lookupTask?.cancel()
        runProbe()
        refresh()
        window?.makeKeyAndOrderFront(nil)
        // One timer, only while the window is open.
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, self.window?.isVisible == true else { self?.timer?.invalidate(); self?.timer = nil; return }
            self.refresh()
        }
    }
    /// Shows a library row — playing or not — with its directory record and what its server actually answers.
    func present(inspecting entry: RadioListing, over anchor: NSWindow?) {
        present(over: anchor)
        inspected = entry; listing = entry
        runProbe()
        refresh()
    }
    private func runProbe() {
        probeTask?.cancel(); probe = nil
        guard let address = inspected?.address ?? engine.station?.address else { return }
        probeTask = Task { @MainActor [weak self] in
            let result = await StreamReply.run(address)
            guard let self, !Task.isCancelled, (self.inspected?.address ?? self.engine.station?.address) == address else { return }
            self.probe = result; self.refresh()
        }
    }
    /// A different station started: the directory record no longer applies.
    func stationChanged() { if inspected != nil { return }; runProbe(); listing = nil; lookupMessage = nil; lookupTask?.cancel(); if window?.isVisible == true { refresh() } }

    func refresh() {
        let station = inspected?.station ?? engine.station
        let playing = inspected == nil || inspected?.address == engine.station?.address
        let info = playing ? engine.streamInfo : nil
        func set(_ name: String, _ text: String) { rows.first { $0.0 == name }?.1.stringValue = text }
        set("Station", station?.name ?? "—")
        set("Stream", station?.address ?? "—")
        set("Now playing", station == nil || !playing ? "—" : engine.title)
        set("Status", !playing ? "Not playing" : engine.status.rawValue.capitalized + (engine.status == .playing ? "" : " — " + engine.detail.capitalized))
        if let info {
            let channels = info.channels == 1 ? "mono" : info.channels == 2 ? "stereo" : "\(info.channels) channels"
            set("Format", "\(info.codec) · \(String(format: "%g", info.sampleRate / 1000)) kHz · \(channels)")
            set("Bitrate", info.kbps.map { "\($0) kb/s (measured from the connection)" } ?? "measuring…")
            let behind = Int(info.delay.rounded()), kept = Int(info.bufferedSeconds.rounded())
            set("Buffer", String(format: "%d:%02d kept for rewind", kept / 60, kept % 60) + (behind >= 2 ? String(format: " · %d:%02d behind live", behind / 60, behind % 60) : " · live"))
            set("Leveling", engine.leveling ? String(format: "on, %+.1f dB", info.levelDb) : "off")
        } else {
            let reason = station == nil || !playing ? "—" : engine.usesFallbackPlayer ? "macOS player (no readouts, EQ or leveling for this stream)" : "—"
            for name in ["Format", "Bitrate", "Buffer", "Leveling"] { set(name, reason) }
        }
        set("Country", listing.map { $0.country.isEmpty ? "—" : $0.country } ?? "—")
        set("Genre", listing.map { $0.tags.isEmpty ? "—" : $0.tags.replacingOccurrences(of: ",", with: ", ") } ?? "—")
        set("Directory", listing.map { "\($0.name) · \($0.codec.isEmpty ? "?" : $0.codec) \($0.bitrate > 0 ? "\($0.bitrate) kb/s" : "") · \($0.votes) votes" } ?? lookupMessage ?? "—")
        let reply = probe
        set("HTTP", reply?.status ?? (station == nil ? "—" : "testing…"))
        set("Content type", reply?.contentType ?? "—")
        set("Server", reply?.server ?? "—")
        set("ICY", reply?.icy ?? "—")
        set("First bytes", reply?.sniff ?? "—")
        set("Final URL", reply?.finalURL ?? "—")
        lookup.isEnabled = station != nil && lookupTask == nil && inspected == nil
        homepage.isEnabled = homepageURL != nil
        lookup.needsDisplay = true; homepage.needsDisplay = true
    }
    private var homepageURL: URL? {
        guard let text = listing?.homepage, let url = URL(string: text), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return url
    }
    @objc private func lookUp() {
        guard let station = engine.station else { return }
        lookupMessage = "Looking up…"; refresh()
        lookupTask = Task { @MainActor [weak self] in
            let found = await self?.directory.refreshed(uuid: station.id.uuidString)
            guard let self, self.engine.station?.id == station.id else { return }
            self.lookupTask = nil
            self.listing = found
            self.lookupMessage = found == nil ? "Not listed in Radio Browser, or it can’t be reached right now." : nil
            self.refresh()
        }
    }
    @objc private func openHomepage() { if let url = homepageURL { NSWorkspace.shared.open(url) } }
    @objc private func copyURL() {
        guard let address = inspected?.address ?? engine.station?.address else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(address, forType: .string)
    }
    @objc private func dismiss() { probeTask?.cancel(); window?.orderOut(nil); timer?.invalidate(); timer = nil }
}

/// Asks a stream's server the way the player does, and reports what came back, so a station that opens in a browser
/// but not here can be told apart: refusal, redirect, wrong type, or data the decoder wouldn't recognise.
enum StreamReply {
    struct Result { var status, contentType, server, icy, sniff, finalURL: String }

    static func run(_ address: String) async -> Result {
        guard let url = URL(string: address), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            return Result(status: "Not an http(s) address", contentType: "—", server: "—", icy: "—", sniff: "—", finalURL: "—")
        }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10; config.urlCache = nil; config.httpCookieStorage = nil
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.setValue("1", forHTTPHeaderField: "Icy-MetaData")
        request.setValue("RadioPocket/0.8", forHTTPHeaderField: "User-Agent")
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else {
                return Result(status: "No HTTP response", contentType: "—", server: "—", icy: "—", sniff: "—", finalURL: "—")
            }
            func header(_ name: String) -> String? { http.value(forHTTPHeaderField: name).flatMap { $0.isEmpty ? nil : $0 } }
            var head = Data()
            do { for try await byte in bytes { head.append(byte); if head.count >= 16 { break } } } catch {}
            let icy = [header("icy-name").map { "name " + $0 }, header("icy-metaint").map { "metaint " + $0 }, header("icy-br").map { "\($0) kb/s" }]
                .compactMap { $0 }.joined(separator: " · ")
            let final = http.url?.absoluteString
            return Result(status: "\(http.statusCode) \(HTTPURLResponse.localizedString(forStatusCode: http.statusCode))",
                          contentType: header("Content-Type") ?? "none", server: header("Server") ?? "—", icy: icy.isEmpty ? "—" : icy,
                          sniff: describe(head), finalURL: final == address ? "same" : final ?? "—")
        } catch {
            return Result(status: error.localizedDescription, contentType: "—", server: "—", icy: "—", sniff: "—", finalURL: "—")
        }
    }

    static func describe(_ head: Data) -> String {
        guard !head.isEmpty else { return "none received" }
        let hex = head.prefix(8).map { String(format: "%02x", $0) }.joined(separator: " ")
        let text = String(decoding: head, as: UTF8.self).lowercased()
        let kind: String
        if head.starts(with: [0x49, 0x44, 0x33]) { kind = "MP3 (ID3)" }
        else if head.starts(with: [0x4f, 0x67, 0x67, 0x53]) { kind = "Ogg" }
        else if head.count >= 2, head[head.startIndex] == 0xff, head[head.startIndex + 1] & 0xf6 == 0xf0 { kind = "AAC (ADTS)" }
        else if head.count >= 2, head[head.startIndex] == 0xff, head[head.startIndex + 1] & 0xe0 == 0xe0 { kind = "MP3" }
        else if text.hasPrefix("#extm3u") || text.hasPrefix("[playlist]") { kind = "playlist" }
        else if text.hasPrefix("<") { kind = "web page" }
        else if text.hasPrefix("icy ") { kind = "ICY status line" }
        else { kind = "unrecognised" }
        return "\(kind) · \(hex)"
    }
}
