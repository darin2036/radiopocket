import Foundation
import Darwin

struct RadioListing: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var address: String
    var tags: String
    var country: String
    var countryCode: String
    var codec: String
    var bitrate: Int
    var votes: Int
    var clicks: Int
    var hls: Bool
    var directoryID: String?
    /// The station's own website (http/https only), when the directory lists one.
    var homepage = ""
    /// Which directory the listing came from; display only, never stored.
    var sourceName: String?

    /// A station worth importing: it has a real name (not blank, a bare web address or just symbols) and its address isn't a page or image.
    static func isViable(name: String, address: URL) -> Bool {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name.contains(where: \.isLetter) || name.contains(where: \.isNumber) else { return false }
        let lower = name.lowercased()
        if lower.contains("://") || lower.hasPrefix("www.") || (!lower.contains(" ") && lower == address.host?.lowercased()) { return false }
        let notAudio: Set<String> = ["jpg", "jpeg", "png", "gif", "svg", "ico", "html", "htm", "css", "js", "json", "xml", "txt", "pdf", "zip"]
        return !notAudio.contains(address.pathExtension.lowercased())
    }

    var likelyPlayable: Bool {
        // Lists that carry no codec (station lists, saved stations) get the benefit of the doubt.
        (directoryID == nil && codec.isEmpty) || hls || ["MP3", "AAC", "AAC+", "AAC-LC", "HE-AAC", "HE-AACV2", "OPUS", "OGG", "VORBIS"].contains(codec.uppercased())
    }
    /// Quality on a 0–5 scale from codec and bitrate, so 64 kbps HE-AAC and 128 kbps MP3 compare fairly. 0 means unknown.
    var quality: Int {
        let name = codec.uppercased()
        if ["FLAC", "ALAC", "WAV", "PCM"].contains(name) { return 5 }
        guard bitrate > 0 else { return 0 }
        // Rough MP3-equivalent kbps: newer codecs sound the same at a lower rate.
        let factor: Double
        switch name {
        case "OPUS": factor = 2.0
        case "AAC+", "HE-AAC", "HE-AACV2", "AACP": factor = 1.9
        case "AAC", "AAC-LC": factor = 1.4
        case "OGG", "VORBIS": factor = 1.3
        default: factor = 1.0
        }
        let effective = Double(bitrate) * factor
        return effective < 56 ? 1 : effective < 96 ? 2 : effective < 150 ? 3 : effective < 224 ? 4 : 5
    }
    var qualityStars: String { quality == 0 ? "—" : String(repeating: "★", count: quality) + String(repeating: "☆", count: 5 - quality) }
    /// Orders listings by a column key; ties fall back to name so the order is stable.
    static func ordered(_ rows: [RadioListing], by order: String, reverse: Bool) -> [RadioListing] {
        func number(_ r: RadioListing) -> Int? {
            switch order {
            case "bitrate": return r.bitrate
            case "quality": return r.quality * 100_000 + r.bitrate
            case "votes": return r.votes
            case "clickcount": return r.clicks
            default: return nil
            }
        }
        func text(_ r: RadioListing) -> String {
            switch order {
            case "tags": return r.tags
            case "country": return r.country
            case "codec": return r.formatLabel
            default: return r.name
            }
        }
        func name(_ a: RadioListing, _ b: RadioListing) -> Bool { a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending }
        return rows.sorted { a, b in
            if let x = number(a), let y = number(b) { return x == y ? name(a, b) : (reverse ? x > y : x < y) }
            // Listings with no value for a text column always sink to the bottom.
            let x = text(a), y = text(b)
            if x.isEmpty != y.isEmpty { return !x.isEmpty }
            let result = x.localizedCaseInsensitiveCompare(y)
            return result == .orderedSame ? name(a, b) : (reverse ? result == .orderedDescending : result == .orderedAscending)
        }
    }
    var formatLabel: String { hls ? (codec.isEmpty ? "HLS" : "\(codec)/HLS") : (codec.isEmpty ? "—" : codec) }
    var station: Station { Station(id: UUID(uuidString: id) ?? UUID(), name: name, address: address) }
    init(station: Station) {
        id = station.id.uuidString; name = station.name; address = station.address
        tags = ""; country = ""; countryCode = ""; codec = ""; bitrate = 0; votes = 0; clicks = 0; hls = false; directoryID = nil; sourceName = nil
    }
    init(id: String, name: String, address: String, tags: String, country: String, countryCode: String, codec: String, bitrate: Int, votes: Int, clicks: Int, hls: Bool, sourceName: String?) {
        self.id = id; self.name = name; self.address = address; self.tags = tags; self.country = country; self.countryCode = countryCode
        self.codec = codec; self.bitrate = bitrate; self.votes = votes; self.clicks = clicks; self.hls = hls; self.directoryID = nil; self.sourceName = sourceName
    }
    private enum Keys: String, CodingKey {
        case stationuuid, name, url, url_resolved, tags, country, countrycode, codec, bitrate, votes, clickcount, hls, homepage
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        func string(_ key: Keys) -> String { (try? c.decode(String.self, forKey: key)) ?? "" }
        func number(_ key: Keys) -> Int { (try? c.decode(Int.self, forKey: key)) ?? Int(string(key)) ?? 0 }
        let uuid = string(.stationuuid)
        guard UUID(uuidString: uuid) != nil else { throw RadioError.message("Invalid station identifier.") }
        guard let url = [string(.url_resolved), string(.url)].compactMap({ try? StreamAddress.parse($0) }).first else {
            throw RadioError.message("The directory entry has no HTTP audio URL.")
        }
        id = uuid; directoryID = uuid; sourceName = nil; address = url.absoluteString
        name = Self.clean(string(.name), limit: 300)
        guard Self.isViable(name: name, address: url) else { throw RadioError.message("The directory entry isn't a usable station.") }
        tags = Self.clean(string(.tags), limit: 500)
        countryCode = string(.countrycode).uppercased()
        country = Locale.current.localizedString(forRegionCode: countryCode) ?? Self.clean(string(.country), limit: 100)
        codec = Self.clean(string(.codec), limit: 24).uppercased()
        bitrate = max(0, number(.bitrate)); votes = max(0, number(.votes)); clicks = max(0, number(.clickcount))
        hls = number(.hls) == 1
        homepage = Self.clean(string(.homepage), limit: 300)
    }
    // This is an API value object, not a second on-disk station database.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(id, forKey: .stationuuid); try c.encode(name, forKey: .name); try c.encode(address, forKey: .url)
        try c.encode(address, forKey: .url_resolved); try c.encode(tags, forKey: .tags)
        try c.encode(country, forKey: .country); try c.encode(countryCode, forKey: .countrycode)
        try c.encode(codec, forKey: .codec); try c.encode(bitrate, forKey: .bitrate); try c.encode(votes, forKey: .votes)
        try c.encode(clicks, forKey: .clickcount); try c.encode(hls ? 1 : 0, forKey: .hls); try c.encode(homepage, forKey: .homepage)
    }
    private static func clean(_ value: String, limit: Int) -> String {
        String(String(value.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : String($0) }.joined()).trimmingCharacters(in: .whitespacesAndNewlines).prefix(limit))
    }
}

struct DirectoryQuery: Hashable {
    var name = ""
    var genre = ""
    var countryCode = ""
    var codec = ""
    var minimumBitrate = 0
    var order = "clickcount"
    var reverse = true
    var supportedOnly = true
    /// "all", or the identifier of one `DirectorySource`.
    var sourceID = "all"
    var offset = 0
    static let pageSize = 100
    var items: [URLQueryItem] {
        var result = [URLQueryItem(name: "hidebroken", value: "true"), .init(name: "limit", value: "\(Self.pageSize)"),
                      .init(name: "offset", value: "\(max(0, offset))"), .init(name: "order", value: order == "quality" ? "bitrate" : order), .init(name: "reverse", value: reverse ? "true" : "false")]
        for (key, value) in [("name", serverName), ("tag", genre), ("countrycode", countryCode), ("codec", codec)] {
            let value = String(value.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
            if !value.isEmpty { result.append(.init(name: key, value: value)) }
        }
        if !genre.isEmpty { result.append(.init(name: "tagExact", value: "true")) }
        if minimumBitrate > 0 { result.append(.init(name: "bitrateMin", value: "\(minimumBitrate)")) }
        return result
    }
    var searchWords: [String] { StationSearch.words(name) }
    /// Radio Browser matches the name as one phrase, so several words go up as the longest one and the rest are checked here.
    private var serverName: String {
        let words = name.split(whereSeparator: \.isWhitespace)
        return words.count > 1 ? String(words.max { $0.count < $1.count }!) : name
    }
    func matchesLocal(_ station: Station) -> Bool {
        searchWords.isEmpty || StationSearch.matches(searchWords, in: [station.name, station.address])
    }
    func matchesName(_ listing: RadioListing) -> Bool {
        searchWords.isEmpty || StationSearch.matches(searchWords, in: [listing.name, listing.tags])
    }
}

struct DirectoryPage {
    var stations: [RadioListing]
    var hasMore: Bool
    var rawCount: Int
    var cached: Bool = false
    /// When a saved page was last fetched from the directories; nil for a live response.
    var updated: Date?
}

private struct DirectoryRows: Decodable {
    var rows: [RadioListing] = []
    var count = 0
    private struct Entry: Decodable {
        let value: RadioListing?
        init(from decoder: Decoder) { value = try? RadioListing(from: decoder) }
    }
    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        guard (container.count ?? 0) <= 200 else { throw RadioError.message("The directory returned too many stations for one page.") }
        var seen = Set<String>()
        while !container.isAtEnd {
            guard count < 200 else { throw RadioError.message("The directory returned too many stations for one page.") }
            let entry = try container.decode(Entry.self); count += 1
            if let station = entry.value, seen.insert(station.id).inserted { rows.append(station) }
        }
    }
}

/// One Radio Browser-style server: the public mirrors, or a compatible server the user added.
actor RadioBrowserDirectory: DirectoryBackend {
    private var mirrors: [URL]
    private var discovered = false
    private let session: URLSession
    private var cache: [DirectoryQuery: (Date, DirectoryPage)] = [:]
    private var recency: [DirectoryQuery] = []
    private let injected: Bool
    private let label: String
    /// Only the public Radio Browser counts plays and refreshes saved stations; a third-party server must not receive those.
    private let primary: Bool

    init(baseURLs: [URL]? = nil, label: String = "Radio Browser", primary: Bool = true) {
        mirrors = baseURLs ?? [URL(string: "https://all.api.radio-browser.info")!]
        injected = baseURLs != nil
        self.label = label; self.primary = primary
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = 25
        config.httpAdditionalHeaders = ["User-Agent": "RadioPocket/0.3", "Accept": "application/json"]
        session = URLSession(configuration: config)
    }

    func search(_ query: DirectoryQuery, refresh: Bool = false) async throws -> DirectoryPage {
        try Task.checkCancellation()
        if !refresh, let entry = cache[query], Date().timeIntervalSince(entry.0) < 300 {
            var page = entry.1; page.cached = true; return page
        }
        await discover()
        let data = try await request(path: "/json/stations/search", items: query.items, validate: { _ = try JSONDecoder().decode(DirectoryRows.self, from: $0) })
        var page = try Self.decodePage(data, query: query)
        page.stations = page.stations.map { var row = $0; row.sourceName = label; if !primary { row.directoryID = nil }; return row }
        try Task.checkCancellation()
        cache[query] = (Date(), page)
        recency.removeAll { $0 == query }; recency.append(query)
        while recency.count > 6 { cache.removeValue(forKey: recency.removeFirst()) }
        return page
    }

    /// Pages held in memory right now (for checks).
    var cachedPages: Int { cache.count }
    func trim() async {
        cache = cache.filter { !DirectoryCacheAge.isIdle($0.value.0) }
        recency.removeAll { cache[$0] == nil }
    }
    func release() async { cache = [:]; recency = [] }

    static func decodePage(_ data: Data, query: DirectoryQuery) throws -> DirectoryPage {
        let values = try JSONDecoder().decode(DirectoryRows.self, from: data)
        var stations = query.supportedOnly ? values.rows.filter(\.likelyPlayable) : values.rows
        if query.searchWords.count > 1 { stations = stations.filter(query.matchesName) }
        return DirectoryPage(stations: Array(stations.prefix(DirectoryQuery.pageSize)), hasMore: values.count >= DirectoryQuery.pageSize, rawCount: values.count)
    }

    /// The directory’s current record for a station saved from it (its stream address may have changed since).
    func refreshed(uuid: String) async -> RadioListing? {
        guard UUID(uuidString: uuid) != nil else { return nil }
        await discover()
        guard let data = try? await request(path: "/json/stations/byuuid/\(uuid)", items: [], validate: { _ = try JSONDecoder().decode(DirectoryRows.self, from: $0) }) else { return nil }
        return try? JSONDecoder().decode(DirectoryRows.self, from: data).rows.first
    }

    /// Other directory stations with a similar name, most-voted first, excluding the failing stream.
    func alternates(for station: Station, limit: Int = 3) async -> [RadioListing] {
        let words = station.name.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).prefix(3).joined(separator: " ")
        guard !words.isEmpty else { return [] }
        var query = DirectoryQuery(); query.name = words; query.order = "votes"
        guard let page = try? await search(query) else { return [] }
        return Array(page.stations.filter { $0.address != station.address && $0.id != station.id.uuidString }.prefix(limit))
    }

    // Radio Browser asks clients to count only intentional station play actions.
    func countPlay(_ identifier: String) async {
        guard UUID(uuidString: identifier) != nil else { return }
        _ = try? await request(path: "/json/url/\(identifier)", items: [], limit: 32768)
    }

    private func discover() async {
        guard !discovered, !injected else { return }
        discovered = true
        let hosts = await Task.detached(priority: .utility) { Self.lookupMirrors() }.value
        if !hosts.isEmpty { mirrors = hosts.shuffled().compactMap { URL(string: "https://\($0)") } }
    }
    private static func lookupMirrors() -> [String] {
        var hints = addrinfo(); hints.ai_family = AF_UNSPEC; hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo("all.api.radio-browser.info", "443", &hints, &result) == 0, let first = result else { return [] }
        defer { freeaddrinfo(first) }
        var hosts = Set<String>()
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let info = cursor {
            var name = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(info.pointee.ai_addr, info.pointee.ai_addrlen, &name, socklen_t(name.count), nil, 0, NI_NAMEREQD) == 0 {
                let host = String(cString: name).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
                if host.hasSuffix(".api.radio-browser.info") { hosts.insert(host) }
            }
            cursor = info.pointee.ai_next
        }
        return Array(hosts)
    }
    private func request(path: String, items: [URLQueryItem], limit: Int = 2_097_152, validate: ((Data) throws -> Void)? = nil) async throws -> Data {
        var lastError: Error = RadioError.message("The radio directory is unavailable. Your favorites and direct streams still work.")
        for base in mirrors.prefix(3) {
            try Task.checkCancellation()
            var components = URLComponents(url: base, resolvingAgainstBaseURL: false)!
            components.path = path; components.queryItems = items.isEmpty ? nil : items
            do {
                let request = URLRequest(url: components.url!, timeoutInterval: 12)
                let (bytes, response) = try await session.bytes(for: request)
                defer { bytes.task.cancel() }
                guard let response = response as? HTTPURLResponse, (200...299).contains(response.statusCode) else {
                    throw RadioError.message("The directory server is temporarily unavailable. Try Refresh.")
                }
                guard response.expectedContentLength <= limit else { throw RadioError.message("The directory response exceeded its size limit.") }
                var data = Data(); data.reserveCapacity(min(max(0, Int(response.expectedContentLength)), limit))
                for try await byte in bytes {
                    if data.count % 4096 == 0 { try Task.checkCancellation() }
                    guard data.count < limit else { throw RadioError.message("The directory response exceeded its size limit.") }
                    data.append(byte)
                }
                try validate?(data)
                return data
            } catch {
                try Task.checkCancellation()
                lastError = error
            }
        }
        throw lastError
    }
}

/// Every enabled directory behind one search. Radio Browser stays the primary source; the hub adds the rest and merges them.
actor RadioDirectory {
    private let radioBrowser: RadioBrowserDirectory
    private var sources = DirectorySource.resolved(nil)
    private var backends: [String: (key: String, backend: DirectoryBackend)] = [:]
    private let cache: StationCache?
    private var pending: [(key: String, query: DirectoryQuery)] = []
    private var queued = Set<String>()
    private var draining = false
    private var failures = 0
    private var pausedUntil = Date.distantPast
    private var schedule: Task<Void, Never>?
    private var trimTask: Task<Void, Never>?
    private let dead: DeadStations?
    private var probing = true
    private var vetting = false
    /// A saved page this young is used as is; older ones are shown at once and refreshed behind the scenes.
    static let freshFor: TimeInterval = 6 * 3600
    /// Past this a saved page is ignored while the network works (it is still the fallback when it doesn't).
    static let expiresAfter: TimeInterval = 7 * 86_400
    /// The views opened first, and how many 100-station pages of each are kept warm.
    static let warmViews: [(order: String, reverse: Bool, pages: Int)] = [("clickcount", true, 5), ("votes", true, 2), ("name", false, 2)]

    init(baseURLs: [URL]? = nil, cache: StationCache? = nil, dead: DeadStations? = nil) {
        radioBrowser = RadioBrowserDirectory(baseURLs: baseURLs); self.cache = cache; self.dead = dead
    }

    /// Whether directory entries that carry no health data are checked in the background.
    func setChecking(_ on: Bool) { probing = on }
    func forgetDeadStations() { dead?.clear() }

    /// Applies the user's directory list. Backends are kept between calls so their caches survive.
    func configure(_ list: [DirectorySource]) {
        sources = DirectorySource.resolved(list)
        var next: [String: (key: String, backend: DirectoryBackend)] = [:]
        for source in sources where source.enabled && !(source.kind == .radioBrowser) {
            let key = "\(source.kind.rawValue)|\(source.url ?? "")|\(source.name)"
            if let existing = backends[source.id], existing.key == key { next[source.id] = existing }
            else if let backend = source.makeBackend() { next[source.id] = (key, backend) }
        }
        backends = next
    }

    /// Browsing views come from disk when saved: instantly, and offline. A page older than `freshFor` is still returned at once
    /// and queued for a quiet refresh, so what the user sees never waits on the network. Refresh and typed searches go live.
    func search(_ query: DirectoryQuery, refresh: Bool = false) async throws -> DirectoryPage {
        let page = try await browse(query, refresh: refresh)
        guard let dead else { return page }
        checkInBackground(page.stations)
        return dead.filter(page)
    }

    private func browse(_ query: DirectoryQuery, refresh: Bool) async throws -> DirectoryPage {
        scheduleTrim()
        guard let cache, let key = cacheKey(query) else { return try await live(query, refresh: refresh) }
        let stored = cache.load(key)
        if !refresh, let stored {
            let age = Date().timeIntervalSince(stored.savedAt)
            if age < Self.expiresAfter {
                if age > Self.freshFor { enqueue(key, query) }
                return stored.page
            }
        }
        do {
            let page = try await live(query, refresh: refresh)
            cache.store(page, key: key)
            return page
        } catch {
            if Task.isCancelled || error is CancellationError || refresh { throw error }
            if let stored { return stored.page }
            throw error
        }
    }

    // MARK: Freeing memory

    /// Frees the in-memory copies of downloaded pages and catalogs: only the idle ones, or all of them when `everything`.
    func releaseMemory(everything: Bool = false) async {
        for entry in backends.values { if everything { await entry.backend.release() } else { await entry.backend.trim() } }
        if everything { await radioBrowser.release() } else { await radioBrowser.trim() }
    }

    /// One pending trim, pushed back by every search: browsing leaves nothing behind once it has been quiet for a while,
    /// and nothing wakes up while the directory isn't being used.
    private func scheduleTrim() {
        trimTask?.cancel()
        trimTask = Task(priority: .utility) { [weak self] in
            try? await Task.sleep(for: .seconds(DirectoryCacheAge.trimDelay))
            guard !Task.isCancelled else { return }
            await self?.releaseMemory()
        }
    }

    private func cacheKey(_ query: DirectoryQuery) -> String? {
        let active = sources.filter { $0.enabled && (query.sourceID == "all" || $0.id == query.sourceID) }
        return cache?.key(for: query, sources: active.map { $0.id + "@" + ($0.url ?? "") })
    }

    // MARK: Background refresh

    /// Starts the quiet refresh loop: a short wait so the player comes up first, then a check every 45 minutes.
    /// A check only queues pages that have gone stale, so most of them do nothing.
    func startBackgroundRefresh() {
        guard cache != nil, schedule == nil else { return }
        _ = NetworkCost.shared
        schedule = Task(priority: .utility) { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            while !Task.isCancelled {
                await self?.warm()
                try? await Task.sleep(for: .seconds(45 * 60), tolerance: .seconds(5 * 60))
            }
        }
    }
    func stopBackgroundRefresh() { schedule?.cancel(); schedule = nil; pending.removeAll(); queued.removeAll() }
    func clearSavedStations() { pending.removeAll(); queued.removeAll(); cache?.clear() }

    /// Queues the opening views whose saved pages are missing or stale.
    func warm() {
        guard let cache, Date() >= pausedUntil else { return }
        for view in Self.warmViews {
            for page in 0..<view.pages {
                var query = DirectoryQuery(); query.order = view.order; query.reverse = view.reverse; query.offset = page * DirectoryQuery.pageSize
                guard let key = cacheKey(query) else { continue }
                if let age = cache.age(of: key), age < Self.freshFor { continue }
                enqueue(key, query)
            }
        }
    }

    private func enqueue(_ key: String, _ query: DirectoryQuery) {
        guard Date() >= pausedUntil, queued.insert(key).inserted else { return }
        pending.append((key, query))
        guard !draining else { return }
        draining = true
        Task(priority: .utility) { await self.drain() }
    }

    /// One request at a time with a pause between them, so a refresh is a trickle rather than a burst.
    private func drain() async {
        while !pending.isEmpty {
            guard BackgroundPolicy.allows() else { pause(minutes: 15); break }
            let item = pending.removeFirst()
            do {
                // Refreshing reuses each directory's short in-memory copy, so a big catalog is downloaded once per round.
                var page = try await live(item.query, refresh: false)
                try Task.checkCancellation()
                // Saved pages are vetted first, so what opens instantly is already free of stations that no longer answer.
                if probing, let dead { vetting = true; await StreamProbe.vet(page.stations, dead: dead); vetting = false; page = dead.filter(page) }
                cache?.store(page, key: item.key); failures = 0
            } catch {
                failures += 1
                if failures >= 2 { pause(minutes: 15); break }
            }
            queued.remove(item.key)
            try? await Task.sleep(for: .seconds(1.5))
        }
        draining = false
        cache?.prune()
        await releaseMemory()
    }
    /// Pages that were not saved (typed searches, deeper pages) are checked quietly after they are shown; the next load leaves out what failed.
    private func checkInBackground(_ rows: [RadioListing]) {
        guard probing, let dead, !vetting, BackgroundPolicy.allows(), rows.contains(where: { $0.directoryID == nil && dead.needsCheck($0.address) }) else { return }
        vetting = true
        Task(priority: .utility) { [weak self] in
            await StreamProbe.vet(rows, dead: dead)
            await self?.finishVetting()
        }
    }
    private func finishVetting() { vetting = false }

    private func pause(minutes: Double) {
        pending.removeAll(); queued.removeAll(); failures = 0
        pausedUntil = Date().addingTimeInterval(minutes * 60)
    }

    private func live(_ query: DirectoryQuery, refresh: Bool) async throws -> DirectoryPage {
        let active = sources.filter { $0.enabled && (query.sourceID == "all" || $0.id == query.sourceID) }
        guard !active.isEmpty else { throw RadioError.message("That directory is turned off. Enable it in Preferences ▸ Directories.") }
        let radioBrowser = radioBrowser, backends = backends
        let results = await withTaskGroup(of: (Int, Result<DirectoryPage, Error>).self) { group in
            for (index, source) in active.enumerated() {
                let backend: DirectoryBackend? = source.kind == .radioBrowser ? radioBrowser : backends[source.id]?.backend
                group.addTask {
                    guard let backend else { return (index, .failure(RadioError.message("\(source.name) isn’t available."))) }
                    do { return (index, .success(try await backend.search(query, refresh: refresh))) }
                    catch { return (index, .failure(error)) }
                }
            }
            var collected: [(Int, Result<DirectoryPage, Error>)] = []
            for await item in group { collected.append(item) }
            return collected.sorted { $0.0 < $1.0 }.map(\.1)
        }
        try Task.checkCancellation()
        let pages = results.compactMap { try? $0.get() }
        guard !pages.isEmpty else {
            if case .failure(let error)? = results.first { throw error }
            throw RadioError.message("The radio directory is unavailable. Your favorites and direct streams still work.")
        }
        if pages.count == 1 {
            var only = pages[0]
            if query.order != "clickcount" { only.stations = RadioListing.ordered(only.stations, by: query.order, reverse: query.reverse) }
            return only
        }
        // Interleave so no single directory fills the page, and drop streams several directories list.
        var merged: [RadioListing] = [], seen = Set<String>()
        for round in 0..<(pages.map { $0.stations.count }.max() ?? 0) {
            for page in pages where round < page.stations.count {
                let row = page.stations[round]
                if seen.insert(row.address).inserted { merged.append(row) }
            }
        }
        if query.order != "clickcount" { merged = RadioListing.ordered(merged, by: query.order, reverse: query.reverse) }
        return DirectoryPage(stations: merged, hasMore: pages.contains(where: \.hasMore), rawCount: pages.reduce(0) { $0 + $1.rawCount }, cached: pages.allSatisfy(\.cached))
    }

    static func decodePage(_ data: Data, query: DirectoryQuery) throws -> DirectoryPage { try RadioBrowserDirectory.decodePage(data, query: query) }
    func refreshed(uuid: String) async -> RadioListing? { await radioBrowser.refreshed(uuid: uuid) }
    func alternates(for station: Station, limit: Int = 3) async -> [RadioListing] { await radioBrowser.alternates(for: station, limit: limit) }
    func countPlay(_ identifier: String) async { await radioBrowser.countPlay(identifier) }
}
