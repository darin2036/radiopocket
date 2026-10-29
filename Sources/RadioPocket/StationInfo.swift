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
    private static let labels = ["Station", "Stream", "Now playing", "Status", "Format", "Bitrate", "Buffer", "Leveling", "Country", "Genre", "Directory"]

    init(engine: RadioEngine, directory: RadioDirectory) {
        self.engine = engine; self.directory = directory
        let window = PlayerWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 340), styleMask: [.borderless], backing: .buffered, defer: false)
        window.title = "Station Info"
        window.isReleasedWhenClosed = false; window.hasShadow = true; window.appearance = NSAppearance(named: .darkAqua)
        super.init(window: window)
        let root = ClassicChrome(frame: NSRect(x: 0, y: 0, width: 460, height: 340)); root.title = "STATION INFO"
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
            button.frame = NSRect(x: x, y: 294, width: 112, height: 23); root.addSubview(button)
        }
        let copy = ClassicButton(title: "Copy URL", target: self, action: #selector(copyURL))
        copy.isBordered = false; copy.frame = NSRect(x: 254, y: 294, width: 82, height: 23); root.addSubview(copy)
        let done = ClassicButton(title: "Close", target: self, action: #selector(dismiss))
        done.isBordered = false; done.keyEquivalent = "\u{1b}"; done.frame = NSRect(x: 364, y: 294, width: 82, height: 23); root.addSubview(done)
    }
    required init?(coder: NSCoder) { fatalError() }

    func present(over player: NSWindow?) {
        if window?.isVisible != true, let player { window?.setFrameTopLeftPoint(NSPoint(x: player.frame.minX, y: player.frame.minY - 8)) }
        listing = nil; lookupMessage = nil; lookupTask?.cancel()
        refresh()
        window?.makeKeyAndOrderFront(nil)
        // One timer, only while the window is open.
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, self.window?.isVisible == true else { self?.timer?.invalidate(); self?.timer = nil; return }
            self.refresh()
        }
    }
    /// A different station started: the directory record no longer applies.
    func stationChanged() { listing = nil; lookupMessage = nil; lookupTask?.cancel(); if window?.isVisible == true { refresh() } }

    func refresh() {
        let station = engine.station, info = engine.streamInfo
        func set(_ name: String, _ text: String) { rows.first { $0.0 == name }?.1.stringValue = text }
        set("Station", station?.name ?? "—")
        set("Stream", station?.address ?? "—")
        set("Now playing", station == nil ? "—" : engine.title)
        set("Status", engine.status.rawValue.capitalized + (engine.status == .playing ? "" : " — " + engine.detail.capitalized))
        if let info {
            let channels = info.channels == 1 ? "mono" : info.channels == 2 ? "stereo" : "\(info.channels) channels"
            set("Format", "\(info.codec) · \(String(format: "%g", info.sampleRate / 1000)) kHz · \(channels)")
            set("Bitrate", info.kbps.map { "\($0) kb/s (measured from the connection)" } ?? "measuring…")
            let behind = Int(info.delay.rounded()), kept = Int(info.bufferedSeconds.rounded())
            set("Buffer", String(format: "%d:%02d kept for rewind", kept / 60, kept % 60) + (behind >= 2 ? String(format: " · %d:%02d behind live", behind / 60, behind % 60) : " · live"))
            set("Leveling", engine.leveling ? String(format: "on, %+.1f dB", info.levelDb) : "off")
        } else {
            let reason = station == nil ? "—" : engine.usesFallbackPlayer ? "macOS player (no readouts, EQ or leveling for this stream)" : "—"
            for name in ["Format", "Bitrate", "Buffer", "Leveling"] { set(name, reason) }
        }
        set("Country", listing.map { $0.country.isEmpty ? "—" : $0.country } ?? "—")
        set("Genre", listing.map { $0.tags.isEmpty ? "—" : $0.tags.replacingOccurrences(of: ",", with: ", ") } ?? "—")
        set("Directory", listing.map { "\($0.name) · \($0.codec.isEmpty ? "?" : $0.codec) \($0.bitrate > 0 ? "\($0.bitrate) kb/s" : "") · \($0.votes) votes" } ?? lookupMessage ?? "—")
        lookup.isEnabled = station != nil && lookupTask == nil
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
        guard let address = engine.station?.address else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(address, forType: .string)
    }
    @objc private func dismiss() { window?.orderOut(nil); timer?.invalidate(); timer = nil }
}
