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

    var likelyPlayable: Bool {
        hls || ["MP3", "AAC", "AAC+", "AAC-LC", "HE-AAC", "HE-AACV2", "OPUS", "OGG", "VORBIS"].contains(codec.uppercased())
    }
    var formatLabel: String { hls ? (codec.isEmpty ? "HLS" : "\(codec)/HLS") : (codec.isEmpty ? "—" : codec) }
    var station: Station { Station(id: UUID(uuidString: id) ?? UUID(), name: name, address: address) }
    init(station: Station) {
        id = station.id.uuidString; name = station.name; address = station.address
        tags = ""; country = ""; countryCode = ""; codec = ""; bitrate = 0; votes = 0; clicks = 0; hls = false; directoryID = nil
    }
    private enum Keys: String, CodingKey {
        case stationuuid, name, url, url_resolved, tags, country, countrycode, codec, bitrate, votes, clickcount, hls
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
        id = uuid; directoryID = uuid; address = url.absoluteString
        name = Self.clean(string(.name), limit: 300)
        if name.isEmpty { name = url.host ?? "Unnamed station" }
        tags = Self.clean(string(.tags), limit: 500)
        countryCode = string(.countrycode).uppercased()
        country = Locale.current.localizedString(forRegionCode: countryCode) ?? Self.clean(string(.country), limit: 100)
        codec = Self.clean(string(.codec), limit: 24).uppercased()
        bitrate = max(0, number(.bitrate)); votes = max(0, number(.votes)); clicks = max(0, number(.clickcount))
        hls = number(.hls) == 1
    }
    // This is an API value object, not a second on-disk station database.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(id, forKey: .stationuuid); try c.encode(name, forKey: .name); try c.encode(address, forKey: .url)
        try c.encode(address, forKey: .url_resolved); try c.encode(tags, forKey: .tags)
        try c.encode(country, forKey: .country); try c.encode(countryCode, forKey: .countrycode)
        try c.encode(codec, forKey: .codec); try c.encode(bitrate, forKey: .bitrate); try c.encode(votes, forKey: .votes)
        try c.encode(clicks, forKey: .clickcount); try c.encode(hls ? 1 : 0, forKey: .hls)
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
    var offset = 0
    static let pageSize = 100
    var items: [URLQueryItem] {
        var result = [URLQueryItem(name: "hidebroken", value: "true"), .init(name: "limit", value: "\(Self.pageSize)"),
                      .init(name: "offset", value: "\(max(0, offset))"), .init(name: "order", value: order), .init(name: "reverse", value: reverse ? "true" : "false")]
        for (key, value) in [("name", name), ("tag", genre), ("countrycode", countryCode), ("codec", codec)] {
            let value = String(value.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
            if !value.isEmpty { result.append(.init(name: key, value: value)) }
        }
        if !genre.isEmpty { result.append(.init(name: "tagExact", value: "true")) }
        if minimumBitrate > 0 { result.append(.init(name: "bitrateMin", value: "\(minimumBitrate)")) }
        return result
    }
    func matchesLocal(_ station: Station) -> Bool {
        name.isEmpty || station.name.localizedCaseInsensitiveContains(name) || station.address.localizedCaseInsensitiveContains(name)
    }
}

struct DirectoryPage {
    var stations: [RadioListing]
    var hasMore: Bool
    var rawCount: Int
    var cached: Bool = false
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

actor RadioDirectory {
    private var mirrors: [URL]
    private var discovered = false
    private let session: URLSession
    private var cache: [DirectoryQuery: (Date, DirectoryPage)] = [:]
    private var recency: [DirectoryQuery] = []
    private let injected: Bool

    init(baseURLs: [URL]? = nil) {
        mirrors = baseURLs ?? [URL(string: "https://all.api.radio-browser.info")!]
        injected = baseURLs != nil
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
        let page = try Self.decodePage(data, query: query)
        try Task.checkCancellation()
        cache[query] = (Date(), page)
        recency.removeAll { $0 == query }; recency.append(query)
        while recency.count > 6 { cache.removeValue(forKey: recency.removeFirst()) }
        return page
    }

    static func decodePage(_ data: Data, query: DirectoryQuery) throws -> DirectoryPage {
        let values = try JSONDecoder().decode(DirectoryRows.self, from: data)
        let stations = query.supportedOnly ? values.rows.filter(\.likelyPlayable) : values.rows
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
