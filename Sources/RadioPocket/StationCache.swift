import Foundation
import CryptoKit
import Network

/// The directory pages people browse, kept on disk so the library opens instantly (even offline) and refreshes quietly afterwards.
/// One small file per page rather than one big database: a page is read only when asked for, so the cache costs no memory at rest,
/// and a page's age is just its file's modification date.
struct StationCache: Sendable {
    struct Entry { var page: DirectoryPage; var savedAt: Date }

    let directory: URL
    static let version = 1
    static let maximumFiles = 300
    static let maximumBytes = 16 * 1_048_576
    static let maximumAge: TimeInterval = 30 * 86_400

    init(directory: URL) { self.directory = directory }

    /// macOS may purge Caches when space runs low; that only costs one slower first open.
    static func standard(dataDirectory: URL? = nil) -> StationCache {
        if let dataDirectory { return StationCache(directory: dataDirectory.appendingPathComponent("Stations", isDirectory: true)) }
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return StationCache(directory: caches.appendingPathComponent("RadioPocket/Stations", isDirectory: true))
    }

    /// Browsing views are worth keeping; typed searches are one-offs and stay in memory only.
    func key(for query: DirectoryQuery, sources: [String]) -> String? {
        guard query.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, (0...100_000).contains(query.offset), !sources.isEmpty else { return nil }
        let text = ["v\(Self.version)", sources.sorted().joined(separator: ","), query.genre.lowercased(), query.countryCode, query.codec,
                    "\(query.minimumBitrate)", query.order, "\(query.reverse)", "\(query.supportedOnly)", "\(query.offset)"].joined(separator: "|")
        return SHA256.hash(data: Data(text.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    private func file(_ key: String) -> URL { directory.appendingPathComponent(key + ".json") }

    func age(of key: String, now: Date = Date()) -> TimeInterval? {
        guard let date = try? file(key).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else { return nil }
        return max(0, now.timeIntervalSince(date))
    }

    func load(_ key: String) -> Entry? {
        let url = file(key)
        guard let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
              let data = try? Data(contentsOf: url), let stored = try? JSONDecoder().decode(Stored.self, from: data), stored.v == Self.version else { return nil }
        // The file is the user's own, but its addresses are played later, so they get the same check as a live response.
        let rows = stored.rows.prefix(200).compactMap { $0.listing }
        var page = DirectoryPage(stations: rows, hasMore: stored.more, rawCount: stored.raw, cached: true)
        page.updated = date
        return Entry(page: page, savedAt: date)
    }

    func store(_ page: DirectoryPage, key: String) {
        let stored = Stored(v: Self.version, more: page.hasMore, raw: page.rawCount, rows: page.stations.prefix(200).map(Row.init))
        let encoder = JSONEncoder(); encoder.outputFormatting = [.withoutEscapingSlashes]
        guard let data = try? encoder.encode(stored) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: file(key), options: .atomic)
    }

    /// Drops pages nobody has refreshed in a month, then the oldest until the folder is back under its caps.
    func prune(now: Date = Date()) {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys) else { return }
        let files = urls.filter { $0.pathExtension == "json" }.compactMap { url -> (URL, Date, Int)? in
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            return (url, values.contentModificationDate ?? .distantPast, values.fileSize ?? 0)
        }.sorted { $0.1 > $1.1 }
        var bytes = 0
        for (index, entry) in files.enumerated() {
            bytes += entry.2
            if now.timeIntervalSince(entry.1) > Self.maximumAge || index >= Self.maximumFiles || bytes > Self.maximumBytes {
                try? FileManager.default.removeItem(at: entry.0); bytes -= entry.2
            }
        }
    }

    func clear() { try? FileManager.default.removeItem(at: directory) }

    /// A deliberately terse on-disk shape; the API-shaped `RadioListing` coding is not a storage format.
    private struct Stored: Codable { var v: Int; var more: Bool; var raw: Int; var rows: [Row] }
    private struct Row: Codable {
        var i: String, n: String, a: String, t: String, c: String, cc: String, k: String
        var b: Int, v: Int, l: Int, h: Bool, d: String?, w: String, s: String?
        init(_ r: RadioListing) {
            i = r.id; n = r.name; a = r.address; t = r.tags; c = r.country; cc = r.countryCode; k = r.codec
            b = r.bitrate; v = r.votes; l = r.clicks; h = r.hls; d = r.directoryID; w = r.homepage; s = r.sourceName
        }
        var listing: RadioListing? {
            guard let url = try? StreamAddress.parse(a) else { return nil }
            var row = RadioListing(id: i, name: n, address: url.absoluteString, tags: t, country: c, countryCode: cc, codec: k, bitrate: b, votes: v, clicks: l, hls: h, sourceName: s)
            row.directoryID = d.flatMap { UUID(uuidString: $0) == nil ? nil : $0 }
            row.homepage = (try? StreamAddress.parse(w).absoluteString) ?? ""
            return row
        }
    }
}

/// Background refreshing is a courtesy: it steps aside whenever the Mac or the connection is under any pressure.
enum BackgroundPolicy {
    static func allows() -> Bool {
        let info = ProcessInfo.processInfo
        if info.isLowPowerModeEnabled { return false }
        if info.thermalState == .serious || info.thermalState == .critical { return false }
        return NetworkCost.shared.allowsBackgroundWork
    }
}

/// Watches the network path so refreshes skip hotspots, Low Data Mode and offline periods.
final class NetworkCost: @unchecked Sendable {
    static let shared = NetworkCost()
    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var path: NWPath?
    private init() {
        monitor.pathUpdateHandler = { [weak self] path in self?.lock.withLock { self?.path = path } }
        monitor.start(queue: DispatchQueue(label: "radiopocket.network-cost", qos: .utility))
    }
    /// Before the first report there is nothing to object to.
    var allowsBackgroundWork: Bool {
        lock.withLock { guard let path else { return true }; return path.status == .satisfied && !path.isExpensive && !path.isConstrained }
    }
}
