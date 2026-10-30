import Foundation
import CryptoKit

/// Built-in and user-supplied station catalogs. Larger full-catalog feeds are opt-in.
struct DirectorySource: Codable, Equatable, Identifiable {
    enum Kind: String, Codable {
        case radioBrowser, somaFM, icecast, lautFM, iprd, radioParadise, curatedStreams, junguler
        /// A server speaking the Radio Browser JSON API (for example a self-hosted mirror).
        case radioBrowserAPI
        /// A hosted M3U / PLS list of stations.
        case stationList
    }
    var id: String
    var name: String
    var kind: Kind
    var url: String?
    var enabled = true

    var builtIn: Bool { Self.defaults.contains { $0.id == id } }
    var detail: String {
        switch kind {
        case .radioBrowser: return "Community directory with tens of thousands of stations"
        case .somaFM: return "Listener-supported, commercial-free channels"
        case .icecast: return "Icecast / Xiph public streams • larger catalog, optional"
        case .lautFM: return "Independent, user-run stations • public, paged search"
        case .iprd: return "International Public Radio Directory • larger catalog, optional"
        case .radioParadise: return "Listener-supported mixes • direct 128 kbps AAC streams"
        case .curatedStreams: return "Mike Pierce’s hand-picked streams • small public playlist collection"
        case .junguler: return "Named genre playlists by Junguler • larger collection, optional"
        case .radioBrowserAPI: return "Radio Browser–compatible server • \(url ?? "")"
        case .stationList: return "M3U / PLS station list • \(url ?? "")"
        }
    }

    static let radioBrowser = DirectorySource(id: "radio-browser", name: "Radio Browser", kind: .radioBrowser)
    static let somaFM = DirectorySource(id: "somafm", name: "SomaFM", kind: .somaFM)
    static let icecast = DirectorySource(id: "icecast", name: "Icecast / Xiph", kind: .icecast, enabled: false)
    static let lautFM = DirectorySource(id: "laut-fm", name: "laut.fm", kind: .lautFM)
    static let iprd = DirectorySource(id: "iprd", name: "IPRD — International Public Radio Directory", kind: .iprd, url: "https://iprd-org.github.io/iprd/site_data/all_stations.m3u", enabled: false)
    static let radioParadise = DirectorySource(id: "radio-paradise", name: "Radio Paradise", kind: .radioParadise)
    static let curatedStreams = DirectorySource(id: "curated-streams", name: "Curated Internet Radio Streams", kind: .curatedStreams)
    static let junguler = DirectorySource(id: "junguler", name: "Junguler Radio Playlists", kind: .junguler, url: "https://raw.githubusercontent.com/junguler/m3u-radio-music-playlists/main/---everything-full.m3u", enabled: false)
    static let defaults = [radioBrowser, somaFM, lautFM, radioParadise, curatedStreams, icecast, iprd, junguler]
    static let maximumCustom = 8

    /// Built-in sources first (keeping any saved on/off choice), then the user's own in the order they were added.
    static func resolved(_ saved: [DirectorySource]?) -> [DirectorySource] {
        let saved = saved ?? []
        let builtIns = defaults.map { base -> DirectorySource in
            var source = base
            if let match = saved.first(where: { $0.id == base.id }) { source.enabled = match.enabled }
            return source
        }
        return builtIns + saved.filter { !$0.builtIn && [.radioBrowserAPI, .stationList].contains($0.kind) && $0.url != nil }
    }

    static func custom(name: String, url: String, kind: Kind) throws -> DirectorySource {
        let address = try StreamAddress.parse(url)
        let clean = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        return DirectorySource(id: "custom-" + UUID().uuidString.lowercased(), name: clean.isEmpty ? (address.host ?? "Directory") : clean, kind: kind, url: address.absoluteString)
    }

    func makeBackend() -> DirectoryBackend? {
        switch kind {
        case .radioBrowser: return nil // Owned by the hub so mirror discovery and playback counting stay in one place.
        case .somaFM: return SomaFMDirectory()
        case .icecast: return IcecastDirectory()
        case .lautFM: return LautFMDirectory()
        case .iprd:
            return StationListDirectory(url: URL(string: Self.iprd.url!)!, label: name, sourceID: id, limit: 8_388_608, maximumEntries: 30_000)
        case .radioParadise: return RadioParadiseDirectory()
        case .curatedStreams: return CuratedStreamsDirectory()
        case .junguler:
            return StationListDirectory(url: URL(string: Self.junguler.url!)!, label: name, sourceID: id, limit: 8_388_608, maximumEntries: 50_000)
        case .radioBrowserAPI:
            guard let url = url.flatMap({ URL(string: $0) }) else { return nil }
            return RadioBrowserDirectory(baseURLs: [url], label: name, primary: false)
        case .stationList:
            guard let url = url.flatMap({ URL(string: $0) }) else { return nil }
            return StationListDirectory(url: url, label: name, sourceID: id)
        }
    }
}

protocol DirectoryBackend: Sendable {
    func search(_ query: DirectoryQuery, refresh: Bool) async throws -> DirectoryPage
    /// Lets go of a downloaded catalog once nobody is using it; the next search simply fetches it again.
    func trim() async
    /// Drops every in-memory copy at once, for memory pressure or a quiet app. Saved pages on disk are untouched.
    func release() async
}
// A backend that holds nothing keeps these defaults. One that does must declare its own as `async` too: in an async context
// Swift prefers the async overload, so a synchronous actor method would lose to these when called on the concrete type.
extension DirectoryBackend { func trim() async {}; func release() async {} }

/// How long an in-memory directory copy may sit before a trim frees it.
enum DirectoryCacheAge {
    static let idle: TimeInterval = 120
    /// A search is followed by one trim this long after it, so nothing downloaded for browsing outlives the browsing.
    static let trimDelay: TimeInterval = 150
    static func isIdle(_ date: Date, now: Date = Date()) -> Bool { now.timeIntervalSince(date) > idle }
}

extension Optional where Wrapped == (Date, [RadioListing]) {
    /// True for a whole-catalog copy that has sat unused long enough to be worth freeing.
    var idle: Bool { map { DirectoryCacheAge.isIdle($0.0) } ?? false }
}

extension UUID {
    /// A repeatable identifier, so a station keeps its row and favorite state between loads.
    static func stable(_ seed: String) -> UUID {
        var bytes = Array(Insecure.MD5.hash(data: Data(seed.utf8)))
        bytes[6] = (bytes[6] & 0x0f) | 0x30; bytes[8] = (bytes[8] & 0x3f) | 0x80
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        func part(_ from: Int, _ to: Int) -> String { String(hex.dropFirst(from).prefix(to - from)) }
        return UUID(uuidString: [part(0, 8), part(8, 12), part(12, 16), part(16, 20), part(20, 32)].joined(separator: "-")) ?? UUID()
    }
}

/// Applies the library window's filters, ordering and paging to directories that return their whole list at once.
enum DirectoryFilter {
    static func page(_ all: [RadioListing], query: DirectoryQuery) -> DirectoryPage {
        let genre = query.genre.lowercased()
        var rows = all.filter { listing in
            if !query.matchesName(listing) { return false }
            if !genre.isEmpty, !listing.tags.lowercased().contains(genre) { return false }
            if !query.countryCode.isEmpty, listing.countryCode != query.countryCode { return false }
            if !query.codec.isEmpty {
                let codec = listing.codec.uppercased()
                if query.codec == "OGG" ? !(codec == "OGG" || codec == "VORBIS") : codec != query.codec { return false }
            }
            if query.minimumBitrate > 0, listing.bitrate < query.minimumBitrate { return false }
            return !query.supportedOnly || listing.likelyPlayable
        }
        rows = RadioListing.ordered(rows, by: query.order, reverse: query.reverse)
        let start = min(max(0, query.offset), rows.count)
        let slice = Array(rows[start..<min(rows.count, start + DirectoryQuery.pageSize)])
        return DirectoryPage(stations: slice, hasMore: start + DirectoryQuery.pageSize < rows.count, rawCount: slice.count)
    }
}

enum DirectoryFetch {
    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.timeoutIntervalForRequest = 12; config.timeoutIntervalForResource = 25
        config.httpAdditionalHeaders = ["User-Agent": "RadioPocket/0.8"]
        return URLSession(configuration: config)
    }()
    static func data(_ url: URL, limit: Int = 2_097_152) async throws -> Data {
        let (bytes, response) = try await session.bytes(from: url)
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw RadioError.message("The directory server is temporarily unavailable. Try Refresh.")
        }
        guard http.expectedContentLength <= limit else { throw RadioError.message("The directory response exceeded its size limit.") }
        var data = Data()
        for try await byte in bytes {
            if data.count % 4096 == 0 { try Task.checkCancellation() }
            guard data.count < limit else { throw RadioError.message("The directory response exceeded its size limit.") }
            data.append(byte)
        }
        return data
    }
}

/// SomaFM's public channel list.
actor SomaFMDirectory: DirectoryBackend {
    private var cache: (Date, [RadioListing])?
    func trim() async { if cache.idle { cache = nil } }
    func release() async { cache = nil }
    private struct Channels: Decodable {
        struct Channel: Decodable {
            struct Playlist: Decodable { var url: String; var format: String; var quality: String }
            var id: String; var title: String; var genre: String?; var listeners: String?; var playlists: [Playlist]?
        }
        var channels: [Channel]
    }

    func search(_ query: DirectoryQuery, refresh: Bool) async throws -> DirectoryPage {
        try Task.checkCancellation()
        var fetched = false
        if refresh || cache == nil || Date().timeIntervalSince(cache!.0) > 600 {
            fetched = true
            let data = try await DirectoryFetch.data(URL(string: "https://somafm.com/channels.json")!, limit: 1_048_576)
            cache = (Date(), Self.listings(Channels.self, data))
        }
        var page = DirectoryFilter.page(cache?.1 ?? [], query: query)
        page.cached = !fetched
        return page
    }

    private static func listings(_ type: Channels.Type, _ data: Data) -> [RadioListing] {
        guard let channels = try? JSONDecoder().decode(type, from: data).channels else { return [] }
        return channels.prefix(200).compactMap { channel in
            let lists = channel.playlists ?? []
            guard let pick = lists.first(where: { $0.format == "mp3" && $0.quality == "highest" })
                    ?? lists.first(where: { $0.format == "aac" && $0.quality == "highest" }) ?? lists.first,
                  let url = try? StreamAddress.parse(pick.url) else { return nil }
            return RadioListing(id: UUID.stable("somafm:" + channel.id).uuidString, name: String(channel.title.prefix(300)), address: url.absoluteString,
                                tags: (channel.genre ?? "").replacingOccurrences(of: "|", with: ", "), country: "United States", countryCode: "US",
                                codec: pick.format.uppercased(), bitrate: 0, votes: 0, clicks: Int(channel.listeners ?? "") ?? 0, hls: false, sourceName: "SomaFM")
        }
    }
}

/// A user-supplied M3U or PLS list of stations.
actor StationListDirectory: DirectoryBackend {
    private let url: URL, label: String, sourceID: String
    private var cache: (Date, [RadioListing])?
    func trim() async { if cache.idle { cache = nil } }
    func release() async { cache = nil }
    private let limit: Int, maximumEntries: Int
    init(url: URL, label: String, sourceID: String, limit: Int = 2_097_152, maximumEntries: Int = 5000) {
        self.url = url; self.label = label; self.sourceID = sourceID; self.limit = limit; self.maximumEntries = maximumEntries
    }

    func search(_ query: DirectoryQuery, refresh: Bool) async throws -> DirectoryPage {
        try Task.checkCancellation()
        var fetched = false
        if refresh || cache == nil || Date().timeIntervalSince(cache!.0) > 600 {
            fetched = true
            let data = try await DirectoryFetch.data(url, limit: limit)
            guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
                throw RadioError.message("The station list couldn’t be read.")
            }
            let rows = Self.parse(text, base: url, label: label, sourceID: sourceID, maximumEntries: maximumEntries)
            guard !rows.isEmpty else { throw RadioError.message("No stations were found in this M3U / PLS list.") }
            cache = (Date(), rows)
        }
        var page = DirectoryFilter.page(cache?.1 ?? [], query: query)
        page.cached = !fetched
        return page
    }

    static func parse(_ text: String, base: URL, label: String, sourceID: String, maximumEntries: Int = 5000) -> [RadioListing] {
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        var entries: [(title: String, group: String, address: String)] = []
        if lines.contains(where: { $0.lowercased() == "[playlist]" }) {
            var files: [Int: String] = [:], titles: [Int: String] = [:]
            for line in lines {
                let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { continue }
                let key = parts[0].lowercased()
                if key.hasPrefix("file"), let i = Int(key.dropFirst(4)) { files[i] = parts[1] }
                else if key.hasPrefix("title"), let i = Int(key.dropFirst(5)) { titles[i] = parts[1] }
            }
            for i in files.keys.sorted() { entries.append((titles[i] ?? "", "", files[i]!)) }
        } else {
            var title = "", group = "", playlistGroup = ""
            for line in lines where !line.isEmpty {
                if line.hasPrefix("#PLAYLIST:") {
                    playlistGroup = String(line.dropFirst(10)).trimmingCharacters(in: .whitespaces)
                        .replacingOccurrences(of: ".m3u", with: "").replacingOccurrences(of: "_", with: " ")
                } else if line.hasPrefix("#EXTGENRE:") {
                    group = String(line.dropFirst(10)).trimmingCharacters(in: .whitespaces)
                } else if line.hasPrefix("#EXTINF") {
                    var quoted = false
                    let separator = line.indices.first { index in
                        if line[index] == "\"" { quoted.toggle() }
                        return line[index] == "," && !quoted
                    }
                    title = separator.map { String(line[line.index(after: $0)...]) } ?? ""
                    if let range = line.range(of: "group-title=\"") { group = String(line[range.upperBound...].prefix { $0 != "\"" }) } else { group = playlistGroup }
                } else if !line.hasPrefix("#") { entries.append((title, group, line)); title = ""; group = "" }
            }
        }
        var seen = Set<String>()
        return entries.prefix(maximumEntries).compactMap { entry in
            guard let address = URL(string: entry.address, relativeTo: base)?.absoluteURL, let valid = try? StreamAddress.parse(address.absoluteString),
                  RadioListing.isViable(name: entry.title, address: valid), seen.insert(valid.absoluteString).inserted else { return nil }
            let ext = valid.pathExtension.lowercased()
            let codec = ["mp3": "MP3", "aac": "AAC", "ogg": "OGG", "opus": "OPUS", "m3u8": "HLS"][ext] ?? ""
            let name = String(entry.title.trimmingCharacters(in: .whitespaces).prefix(300))
            return RadioListing(id: UUID.stable("list:\(sourceID):\(valid.absoluteString)").uuidString, name: name,
                                address: valid.absoluteString, tags: String(entry.group.prefix(500)), country: "", countryCode: "", codec: codec,
                                bitrate: 0, votes: 0, clicks: 0, hls: ext == "m3u8", sourceName: label)
        }
    }
}

/// Public Xiph yellow-pages feed. Only valid HTTP audio entries are retained.
actor IcecastDirectory: DirectoryBackend {
    private var cache: (Date, [RadioListing])?
    func trim() async { if cache.idle { cache = nil } }
    func release() async { cache = nil }
    func search(_ query: DirectoryQuery, refresh: Bool) async throws -> DirectoryPage {
        try Task.checkCancellation()
        let cached = !refresh && cache.map { Date().timeIntervalSince($0.0) < 600 } == true
        if !cached {
            let data = try await DirectoryFetch.data(URL(string: "https://dir.xiph.org/yp.xml")!, limit: 16_777_216)
            cache = (Date(), try Self.parse(data))
        }
        var page = DirectoryFilter.page(cache?.1 ?? [], query: query); page.cached = cached; return page
    }
    static func parse(_ data: Data) throws -> [RadioListing] {
        guard data.count <= 16_777_216,
              !String(decoding: data, as: UTF8.self).localizedCaseInsensitiveContains("<!DOCTYPE") else {
            throw RadioError.message("The Icecast directory returned an unsupported XML document.")
        }
        let reader = IcecastReader(), parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false; parser.delegate = reader
        guard parser.parse(), reader.validRoot else { throw RadioError.message("The Icecast station list couldn’t be read.") }
        try Task.checkCancellation()
        return reader.rows
    }
}

private final class IcecastReader: NSObject, XMLParserDelegate {
    var rows: [RadioListing] = [], validRoot = false
    private var fields: [String: String] = [:], element = "", inEntry = false, seen = Set<String>(), entries = 0
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        element = name
        if name == "directory" { validRoot = true }
        if name == "entry" { fields = [:]; inEntry = true; entries += 1; if entries > 50_000 { parser.abortParsing() } }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inEntry, ["server_name", "server_type", "bitrate", "listen_url", "genre"].contains(element) {
            fields[element] = String(((fields[element] ?? "") + string).prefix(4096))
        }
    }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        defer { element = "" }
        guard name == "entry" else { return }; inEntry = false
        if Task.isCancelled { parser.abortParsing(); return }
        let title = (fields["server_name"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = try? StreamAddress.parse(fields["listen_url"] ?? ""), RadioListing.isViable(name: title, address: url), seen.insert(url.absoluteString).inserted else { return }
        let mime = (fields["server_type"] ?? "").lowercased()
        // Ogg can contain several codecs; leave it as a container rather than guessing Vorbis.
        let codec = ["audio/mpeg": "MP3", "audio/mp3": "MP3", "audio/aac": "AAC", "audio/aacp": "AAC+", "application/ogg": "OGG", "audio/ogg": "OGG", "audio/opus": "OPUS" ][mime] ?? mime.uppercased()
        rows.append(RadioListing(id: UUID.stable("icecast:" + url.absoluteString).uuidString, name: String(title.prefix(300)), address: url.absoluteString,
                                 tags: String((fields["genre"] ?? "").prefix(500)), country: "", countryCode: "", codec: codec,
                                 bitrate: max(0, Int(fields["bitrate"] ?? "") ?? 0), votes: 0, clicks: 0, hls: false, sourceName: "Icecast / Xiph"))
    }
}

/// Paged official APIs keep laut.fm discovery small; never download its complete catalog.
actor LautFMDirectory: DirectoryBackend {
    private var cache: [DirectoryQuery: (Date, DirectoryPage)] = [:]
    private var recency: [DirectoryQuery] = []
    private struct Channel: Decodable {
        var name: String, display_name: String?, stream_url: String?, page_url: String?, genres: [String]?, active: Bool?
    }
    private struct Browse: Decodable { var items: [Channel]; var next_offset: Int? }
    private struct Search: Decodable {
        struct Hit: Decodable { var station: Channel }
        var results: [Hit]; var next_offset: Int?
    }
    static func requestURL(_ query: DirectoryQuery) -> URL {
        let term = [query.name, query.genre].filter { !$0.isEmpty }.joined(separator: " ")
        var url = URLComponents(string: term.isEmpty ? "https://api.laut.fm/stations" : "https://search.api.laut.fm/v1/stations")!
        var items = [URLQueryItem(name: "limit", value: String(DirectoryQuery.pageSize)), URLQueryItem(name: "offset", value: String(max(0, query.offset)))]
        if !term.isEmpty { items += [URLQueryItem(name: "query", value: term), URLQueryItem(name: "fields", value: "name,genres"), URLQueryItem(name: "active", value: "true")] }
        else { items.append(URLQueryItem(name: "order", value: query.reverse ? "desc" : "asc")) }
        url.queryItems = items; return url.url!
    }
    func search(_ query: DirectoryQuery, refresh: Bool) async throws -> DirectoryPage {
        try Task.checkCancellation()
        if !refresh, let (date, page) = cache[query], Date().timeIntervalSince(date) < 600 { var result = page; result.cached = true; return result }
        let data = try await DirectoryFetch.data(Self.requestURL(query))
        let page = try Self.decode(data, query: query)
        cache[query] = (Date(), page); recency.removeAll { $0 == query }; recency.append(query)
        while recency.count > 6 { cache.removeValue(forKey: recency.removeFirst()) }
        return page
    }
    func trim() async {
        cache = cache.filter { !DirectoryCacheAge.isIdle($0.value.0) }
        recency.removeAll { cache[$0] == nil }
    }
    func release() async { cache = [:]; recency = [] }
    static func decode(_ data: Data, query: DirectoryQuery) throws -> DirectoryPage {
        let channels: [Channel], next: Int?
        if query.name.isEmpty && query.genre.isEmpty {
            let response = try JSONDecoder().decode(Browse.self, from: data); channels = response.items; next = response.next_offset
        } else {
            let response = try JSONDecoder().decode(Search.self, from: data); channels = response.results.map(\.station); next = response.next_offset
        }
        guard channels.count <= DirectoryQuery.pageSize else { throw RadioError.message("laut.fm returned too many stations for one page.") }
        var seen = Set<String>()
        let rows: [RadioListing] = channels.compactMap { channel in
            guard channel.active != false, let raw = channel.stream_url, let url = try? StreamAddress.parse(raw), seen.insert(url.absoluteString).inserted else { return nil }
            var row = RadioListing(id: UUID.stable("laut:" + channel.name).uuidString, name: String((channel.display_name ?? channel.name).prefix(300)), address: url.absoluteString,
                                   tags: String((channel.genres ?? []).joined(separator: ", ").prefix(500)), country: "", countryCode: "", codec: "", bitrate: 0, votes: 0, clicks: 0, hls: false, sourceName: "laut.fm")
            row.homepage = channel.page_url.flatMap { try? StreamAddress.parse($0).absoluteString } ?? ""; return row
        }
        var local = query; local.offset = 0
        let filtered = DirectoryFilter.page(rows, query: local)
        return DirectoryPage(stations: filtered.stations, hasMore: next.map { $0 > query.offset } ?? false, rawCount: channels.count)
    }
}

/// The AAC links Radio Paradise publishes for external radio players. No catalog request is needed.
actor RadioParadiseDirectory: DirectoryBackend {
    static let channels: [RadioListing] = [
        ("Main Mix", "aac-128", "eclectic, rock, alternative"),
        ("Mellow Mix", "mellow-128", "mellow, acoustic, chill"),
        ("Rock Mix", "rock-128", "rock"),
        ("World / Etc Mix", "world-etc-128", "world, eclectic")
    ].map { title, path, tags in
        var row = RadioListing(id: UUID.stable("rp:" + path).uuidString, name: "Radio Paradise — " + title,
                               address: "https://stream.radioparadise.com/" + path, tags: tags, country: "United States", countryCode: "US",
                               codec: "AAC", bitrate: 128, votes: 0, clicks: 0, hls: false, sourceName: "Radio Paradise")
        row.homepage = "https://radioparadise.com/"; return row
    }
    func search(_ query: DirectoryQuery, refresh: Bool) async throws -> DirectoryPage {
        try Task.checkCancellation()
        return DirectoryFilter.page(Self.channels, query: query)
    }
}

/// Fetch the small public repository once, rather than requesting every station playlist separately.
actor CuratedStreamsDirectory: DirectoryBackend {
    private var cache: (Date, [RadioListing])?
    func trim() async { if cache.idle { cache = nil } }
    func release() async { cache = nil }
    func search(_ query: DirectoryQuery, refresh: Bool) async throws -> DirectoryPage {
        try Task.checkCancellation()
        let cached = !refresh && cache.map { Date().timeIntervalSince($0.0) < 600 } == true
        if !cached {
            let archive = try await DirectoryFetch.data(URL(string: "https://codeload.github.com/mikepierce/internet-radio-streams/zip/refs/heads/main")!, limit: 1_048_576)
            let text = try Self.playlist(archive)
            let rows = StationListDirectory.parse(text, base: URL(string: "https://raw.githubusercontent.com/mikepierce/internet-radio-streams/main/")!, label: "Curated Internet Radio Streams", sourceID: "curated-streams")
            guard !rows.isEmpty else { throw RadioError.message("The curated collection returned no station playlists.") }
            cache = (Date(), rows)
        }
        var page = DirectoryFilter.page(cache?.1 ?? [], query: query); page.cached = cached; return page
    }
    static func playlist(_ archive: Data) throws -> String {
        guard archive.count <= 1_048_576 else { throw RadioError.message("The curated archive exceeded its size limit.") }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("RadioPocket-Catalog-\(UUID()).zip")
        defer { try? FileManager.default.removeItem(at: url) }
        try archive.write(to: url, options: .atomic)
        let listing = try unzip(["-Z1", url.path], limit: 131_072)
        let paths = String(decoding: listing, as: UTF8.self).components(separatedBy: .newlines).filter { path in
            // Only top-level M3U files; DEMOTED entries and glob/path metacharacters are excluded.
            let parts = path.split(separator: "/", omittingEmptySubsequences: false)
            return parts.count == 2 && !parts.contains(where: { $0 == ".." || $0 == "." || $0.isEmpty }) &&
                path.lowercased().hasSuffix(".m3u") && !path.contains(where: { "*?[]\\:".contains($0) })
        }
        guard !paths.isEmpty, paths.count <= 256 else { throw RadioError.message("The curated archive has an unsupported playlist layout.") }
        try Task.checkCancellation()
        let data = try unzip(["-p", url.path] + paths.sorted(), limit: 2_097_152)
        guard let text = String(data: data, encoding: .utf8) else { throw RadioError.message("The curated playlists couldn’t be read.") }
        return text
    }
    private static func unzip(_ arguments: [String], limit: Int) throws -> Data {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip"); process.arguments = arguments
        process.standardOutput = pipe; process.standardError = FileHandle.nullDevice; process.standardInput = FileHandle.nullDevice
        try process.run()
        do {
            var result = Data()
            while let chunk = try pipe.fileHandleForReading.read(upToCount: 65_536), !chunk.isEmpty {
                try Task.checkCancellation()
                guard result.count + chunk.count <= limit else { throw RadioError.message("The curated playlists exceeded their size limit.") }
                result.append(chunk)
            }
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw RadioError.message("The curated ZIP is damaged or unreadable.") }
            return result
        } catch {
            if process.isRunning { process.terminate() }
            try? pipe.fileHandleForReading.close(); process.waitUntilExit(); throw error
        }
    }
}
