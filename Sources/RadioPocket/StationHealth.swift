import Foundation

/// What a check or a failed playback says about a stream address.
enum StreamVerdict: Equatable {
    case alive
    /// Gone for good as far as anyone can tell: no such host, nothing listening, 404, or a web page instead of audio.
    case dead
    /// Could be the station or could be a hiccup (timeout, 403, 5xx); two of these count as dead.
    case doubtful
    /// Nothing learned, such as being offline.
    case unknown
}

/// Stream addresses the app has found unreachable, kept on disk so the library leaves them out and tries them again later.
/// Only reachability is recorded: a station that connects but can't be decoded is never listed here, so a gap in the
/// app's own format support doesn't hide a working station.
final class DeadStations: @unchecked Sendable {
    struct Record: Codable { var strikes: Int; var last: Date; var alive: Date? }

    static let strikeLimit = 2
    /// A dead address is left out this long, then checked again in case the station came back.
    static let deadFor: TimeInterval = 14 * 86_400
    /// A station that answered is not asked again for this long.
    static let aliveFor: TimeInterval = 3 * 86_400
    /// A doubtful address waits this long before its next check, so two strikes are never the same hiccup.
    static let doubtfulGap: TimeInterval = 12 * 3600
    static let forgetAfter: TimeInterval = 30 * 86_400
    static let maximumRecords = 5_000

    private let file: URL?
    private let lock = NSLock()
    private var records: [String: Record]

    /// A nil file keeps everything in memory only.
    init(file: URL?) {
        self.file = file
        if let file, let data = try? Data(contentsOf: file), let stored = try? JSONDecoder().decode([String: Record].self, from: data) { records = stored }
        else { records = [:] }
    }

    static func standard(dataDirectory: URL? = nil) -> DeadStations {
        if let dataDirectory { return DeadStations(file: dataDirectory.appendingPathComponent("dead-stations.json")) }
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return DeadStations(file: caches.appendingPathComponent("RadioPocket/dead-stations.json"))
    }

    func isDead(_ address: String, now: Date = Date()) -> Bool {
        lock.withLock { Self.dead(records[address], now: now) }
    }

    private static func dead(_ record: Record?, now: Date) -> Bool {
        guard let record, record.strikes >= strikeLimit else { return false }
        return now.timeIntervalSince(record.last) < deadFor
    }

    /// True when the address has no recent answer either way.
    func needsCheck(_ address: String, now: Date = Date()) -> Bool {
        lock.withLock {
            guard let record = records[address] else { return true }
            if record.strikes >= Self.strikeLimit { return now.timeIntervalSince(record.last) >= Self.deadFor }
            if record.strikes > 0 { return now.timeIntervalSince(record.last) >= Self.doubtfulGap }
            return record.alive.map { now.timeIntervalSince($0) >= Self.aliveFor } ?? true
        }
    }

    /// Drops the stations known to be dead; counts and paging are left as the directory reported them.
    func filter(_ page: DirectoryPage, now: Date = Date()) -> DirectoryPage {
        let dead = lock.withLock { records.filter { Self.dead($0.value, now: now) }.keys }
        guard !dead.isEmpty else { return page }
        let gone = Set(dead)
        var result = page
        result.stations = page.stations.filter { !gone.contains($0.address) }
        return result
    }

    func record(_ address: String, _ verdict: StreamVerdict, now: Date = Date()) { record([(address, verdict)], now: now) }

    func record(_ results: [(address: String, verdict: StreamVerdict)], now: Date = Date()) {
        lock.withLock {
            for (address, verdict) in results {
                switch verdict {
                case .alive: records[address] = Record(strikes: 0, last: now, alive: now)
                case .dead: records[address] = Record(strikes: Self.strikeLimit, last: now, alive: nil)
                case .doubtful:
                    let earlier = records[address].flatMap { now.timeIntervalSince($0.last) < Self.deadFor ? $0.strikes : nil } ?? 0
                    records[address] = Record(strikes: min(Self.strikeLimit, earlier + 1), last: now, alive: nil)
                case .unknown: break
                }
            }
            prune(now: now)
            save()
        }
    }

    func count(now: Date = Date()) -> Int { lock.withLock { records.values.filter { Self.dead($0, now: now) }.count } }
    func clear() { lock.withLock { records = [:]; if let file { try? FileManager.default.removeItem(at: file) } } }

    private func prune(now: Date) {
        records = records.filter { now.timeIntervalSince(max($0.value.last, $0.value.alive ?? .distantPast)) < Self.forgetAfter }
        if records.count > Self.maximumRecords {
            let keep = records.sorted { $0.value.last > $1.value.last }.prefix(Self.maximumRecords)
            records = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
    }

    private func save() {
        guard let file else { return }
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }
}

/// Opens a stream just far enough to read its response headers, then lets go.
enum StreamProbe {
    static let concurrency = 6

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    /// Playlists and HLS need more than a header to judge, and addresses on the user's own network are never contacted
    /// on a directory's say-so.
    static func canCheck(_ url: URL) -> Bool {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""), let host = url.host?.lowercased(), !host.isEmpty else { return false }
        if ["m3u", "m3u8", "pls"].contains(url.pathExtension.lowercased()) { return false }
        if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") || host.hasSuffix(".internal") || !host.contains(".") && !host.contains(":") { return false }
        if host.contains(":") { return !(host == "::1" || host.hasPrefix("fe80") || host.hasPrefix("fc") || host.hasPrefix("fd")) }
        let parts = host.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4, parts.count == host.split(separator: ".").count else { return true }
        switch (parts[0], parts[1]) {
        case (0, _), (10, _), (127, _), (169, 254), (192, 168): return false
        case (172, 16...31): return false
        case (100, 64...127): return false
        default: return true
        }
    }

    static func verdict(status: Int, contentType: String) -> StreamVerdict {
        switch status {
        case 200...299: return contentType.hasPrefix("text/html") ? .dead : .alive
        case 404, 410: return .dead
        case 429: return .unknown
        case 400...599: return .doubtful
        default: return .unknown
        }
    }

    static func verdict(error: URLError) -> StreamVerdict {
        switch error.code {
        case .cannotFindHost, .dnsLookupFailed, .cannotConnectToHost: return .dead
        case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff, .cancelled, .callIsActive: return .unknown
        default: return .doubtful
        }
    }

    static func check(_ url: URL) async -> StreamVerdict {
        guard canCheck(url) else { return .unknown }
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.setValue("1", forHTTPHeaderField: "Icy-MetaData")
        request.setValue("RadioPocket/0.8", forHTTPHeaderField: "User-Agent")
        do {
            let (bytes, response) = try await session.bytes(for: request)
            bytes.task.cancel()
            guard let http = response as? HTTPURLResponse else { return .unknown }
            return verdict(status: http.statusCode, contentType: (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased())
        } catch let error as URLError { return verdict(error: error) }
        catch { return .unknown }
    }

    /// Checks the stations of a page that haven't been checked lately, a few at a time, and records what it learns.
    /// Directory entries that carry their own health data (Radio Browser) are left to that directory.
    @discardableResult
    static func vet(_ listings: [RadioListing], dead: DeadStations, limit: Int = 120) async -> Int {
        let due = listings.filter { $0.directoryID == nil && !$0.hls }.compactMap { row -> (String, URL)? in
            guard dead.needsCheck(row.address), let url = URL(string: row.address), canCheck(url) else { return nil }
            return (row.address, url)
        }.prefix(limit)
        guard !due.isEmpty else { return 0 }
        var seen = Set<String>()
        let unique = due.filter { seen.insert($0.0).inserted }
        let results = await withTaskGroup(of: (String, StreamVerdict).self) { group -> [(address: String, verdict: StreamVerdict)] in
            var iterator = unique.makeIterator(), collected: [(address: String, verdict: StreamVerdict)] = []
            func next() { if let item = iterator.next() { group.addTask { (item.0, await check(item.1)) } } }
            for _ in 0..<concurrency { next() }
            while let result = await group.next() { collected.append((result.0, result.1)); if !Task.isCancelled { next() } }
            return collected
        }
        guard !Task.isCancelled else { return 0 }
        dead.record(results)
        return results.count
    }

    /// Whether a playback failure says the station can't be reached, as opposed to the app being unable to play what it sent.
    static func isUnreachable(_ message: String) -> Bool {
        let lower = message.lowercased()
        let appSide = ["audio format", "equalized", "oversized", "isn’t supported", "isn't supported", "not supported", "decoder", "could not be read",
                       "could not initialize", "could not allocate", "invalid", "too many", "playlist"]
        return !appSide.contains { lower.contains($0) }
    }
}
