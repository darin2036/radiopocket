import Foundation
import CryptoKit

/// Built-in and user-supplied station catalogs. Larger full-catalog feeds are opt-in.
struct DirectorySource: Codable, Equatable, Identifiable {
    enum Kind: String, Codable {
        case radioBrowser, somaFM, lautFM, iprd, radioParadise, curatedStreams, junguler, rrradio
        /// Internet TV: 40media Group’s public HLS channels.
        case fortyMedia
        /// A hosted M3U list of Internet TV channels the user added.
        case tvList
        /// A server speaking the Radio Browser JSON API (for example a self-hosted mirror).
        case radioBrowserAPI
        /// Retired built-in; kept only so older saved settings still decode.
        case icecast
        /// A hosted M3U / PLS list of stations.
        case stationList
        case localList, localTVList
    }
    var id: String
    var name: String
    var kind: Kind
    var url: String?
    var enabled = true
    /// Set on a saved built-in the user has deleted, so it stays gone; nil on everything else.
    var removed: Bool?

    var builtIn: Bool { Self.defaults.contains { $0.id == id } }
    /// Whether the directory lists Internet TV channels instead of radio stations.
    var isTV: Bool { kind == .fortyMedia || kind == .tvList || kind == .localTVList }
    /// Whether the source can answer a radio (`video` false) or TV query. A TV list can hold audio-only streams, which go to radio.
    func serves(video: Bool) -> Bool { video ? isTV : (!isTV || kind == .tvList || kind == .localTVList) }
    var detail: String {
        switch kind {
        case .radioBrowser: return "Community directory with tens of thousands of stations"
        case .somaFM: return "Listener-supported, commercial-free channels"
        case .lautFM: return "Independent, user-run stations • public, paged search"
        case .iprd: return "International Public Radio Directory • larger catalog, optional"
        case .radioParadise: return "Listener-supported mixes • direct 128 kbps AAC streams"
        case .curatedStreams: return "Mike Pierce’s hand-picked streams • small public playlist collection"
        case .junguler: return "Named genre playlists by Junguler • larger collection, optional"
        case .rrradio: return "Hand-checked stations from rrradio.org • larger download, optional"
        case .tvList: return "M3U TV channel list • \(url ?? "")"
        case .fortyMedia: return "Live music, movie and entertainment TV channels • free HLS video"
        case .icecast: return ""
        case .radioBrowserAPI: return "Radio Browser–compatible server • \(url ?? "")"
        case .localList, .localTVList: return "Imported playlist • saved on this device"
        case .stationList: return "M3U / PLS station list • \(url ?? "")"
        }
    }

    static let radioBrowser = DirectorySource(id: "radio-browser", name: "Radio Browser", kind: .radioBrowser)
    static let somaFM = DirectorySource(id: "somafm", name: "SomaFM", kind: .somaFM)
    static let lautFM = DirectorySource(id: "laut-fm", name: "laut.fm", kind: .lautFM)
    static let iprd = DirectorySource(id: "iprd", name: "IPRD — International Public Radio Directory", kind: .iprd, url: "https://iprd-org.github.io/iprd/site_data/all_stations.m3u", enabled: false)
    static let radioParadise = DirectorySource(id: "radio-paradise", name: "Radio Paradise", kind: .radioParadise)
    static let fortyMedia = DirectorySource(id: "40media", name: "40media Group", kind: .fortyMedia)
    static let curatedStreams = DirectorySource(id: "curated-streams", name: "Curated Internet Radio Streams", kind: .curatedStreams)
    static let junguler = DirectorySource(id: "junguler", name: "Junguler Radio Playlists", kind: .junguler, url: "https://raw.githubusercontent.com/junguler/m3u-radio-music-playlists/main/---everything-full.m3u", enabled: false)
    static let rrradio = DirectorySource(id: "rrradio", name: "rrradio", kind: .rrradio, url: "https://rrradio.org/stations.json", enabled: false)
    #if os(macOS)
    static let defaults = [radioBrowser, somaFM, lautFM, radioParadise, curatedStreams, iprd, junguler, rrradio, fortyMedia]
    #else
    static let defaults = [radioBrowser, somaFM, lautFM, radioParadise, iprd, junguler, rrradio]
    #endif
    static let maximumCustom = 8

    /// Built-in sources first (keeping any saved on/off choice), then the user's own in the order they were added.
    static func resolved(_ saved: [DirectorySource]?) -> [DirectorySource] {
        let saved = saved ?? []
        let builtIns = defaults.compactMap { base -> DirectorySource? in
            var source = base
            if let match = saved.first(where: { $0.id == base.id }) {
                if match.removed == true { return nil }
                source.enabled = match.enabled
            }
            return source
        }
        return builtIns + saved.filter { !$0.builtIn && [.radioBrowserAPI, .stationList, .tvList, .localList, .localTVList].contains($0.kind) && $0.url != nil }
    }

    static func custom(name: String, url: String, kind: Kind) throws -> DirectorySource {
        let address = try StreamAddress.parse(url)
        let clean = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        return DirectorySource(id: "custom-" + UUID().uuidString.lowercased(), name: clean.isEmpty ? (address.host ?? "Directory") : clean, kind: kind, url: address.absoluteString)
    }

    func makeBackend(safety: TVSafety.Settings = TVSafety.Settings()) -> DirectoryBackend? {
        switch kind {
        case .radioBrowser: return nil // Owned by the hub so mirror discovery and playback counting stay in one place.
        case .somaFM: return SomaFMDirectory()
        case .lautFM: return LautFMDirectory()
        case .iprd:
            return StationListDirectory(url: URL(string: Self.iprd.url!)!, label: name, sourceID: id, limit: 8_388_608, maximumEntries: 30_000)
        case .radioParadise: return RadioParadiseDirectory()
        case .curatedStreams: return CuratedStreamsDirectory()
        case .junguler:
            return StationListDirectory(url: URL(string: Self.junguler.url!)!, label: name, sourceID: id, limit: 8_388_608, maximumEntries: 50_000)
        case .rrradio: return RrradioDirectory()
        case .fortyMedia: return FortyMediaDirectory()
        case .icecast: return nil
        case .radioBrowserAPI:
            guard let url = url.flatMap({ URL(string: $0) }) else { return nil }
            return RadioBrowserDirectory(baseURLs: [url], label: name, primary: false)
        case .localList, .localTVList:
            guard let path = url.flatMap({ URL(string: $0) }), path.isFileURL else { return nil }
            return LocalPlaylistDirectory(url: path, label: name, sourceID: id, video: kind == .localTVList)
        case .stationList:
            guard let url = url.flatMap({ URL(string: $0) }) else { return nil }
            return StationListDirectory(url: url, label: name, sourceID: id)
        case .tvList:
            guard let url = url.flatMap({ URL(string: $0) }) else { return nil }
            return StationListDirectory(url: url, label: name, sourceID: id, limit: 8_388_608, maximumEntries: 20_000, video: true) { TVSafety.rejects(title: $0, group: $1, address: $2, settings: safety) }
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
            if listing.video != query.video { return false }
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
        config.httpAdditionalHeaders = ["User-Agent": "RadioPocket/0.9"]
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
            var id: String; var title: String; var genre: String?; var listeners: String?; var playlists: [Playlist]?; var image: String?; var largeimage: String?
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
            var listing = RadioListing(id: UUID.stable("somafm:" + channel.id).uuidString, name: String(channel.title.prefix(300)), address: url.absoluteString,
                                tags: (channel.genre ?? "").replacingOccurrences(of: "|", with: ", "), country: "United States", countryCode: "US",
                                codec: pick.format.uppercased(), bitrate: 0, votes: 0, clicks: Int(channel.listeners ?? "") ?? 0, hls: false, sourceName: "SomaFM")
            listing.artworkURL = channel.largeimage ?? channel.image
            listing.homepage = "https://somafm.com/" + channel.id + "/"
            return listing
        }
    }
}

/// A user-supplied M3U or PLS list of stations.
actor StationListDirectory: DirectoryBackend {
    private let url: URL, label: String, sourceID: String
    private var cache: (Date, [RadioListing])?
    func trim() async { if cache.idle { cache = nil } }
    func release() async { cache = nil }
    private let limit: Int, maximumEntries: Int, video: Bool
    private let reject: (@Sendable (String, String, URL) -> Bool)?
    init(url: URL, label: String, sourceID: String, limit: Int = 2_097_152, maximumEntries: Int = 5000, video: Bool = false,
         reject: (@Sendable (String, String, URL) -> Bool)? = nil) {
        self.url = url; self.label = label; self.sourceID = sourceID; self.limit = limit; self.maximumEntries = maximumEntries
        self.video = video; self.reject = reject
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
            let rows = Self.parse(text, base: url, label: label, sourceID: sourceID, maximumEntries: maximumEntries, video: video, reject: reject)
            guard !rows.isEmpty else { throw RadioError.message("No stations were found in this M3U / PLS list.") }
            cache = (Date(), rows)
        }
        var page = DirectoryFilter.page(cache?.1 ?? [], query: query)
        page.cached = !fetched
        return page
    }

    static func parse(_ text: String, base: URL, label: String, sourceID: String, maximumEntries: Int = 5000, video: Bool = false,
                      reject: ((_ title: String, _ group: String, _ address: URL) -> Bool)? = nil) -> [RadioListing] {
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        var entries: [(title: String, group: String, address: String, radio: Bool, logo: String, language: String)] = []
        if lines.contains(where: { $0.lowercased() == "[playlist]" }) {
            var files: [Int: String] = [:], titles: [Int: String] = [:]
            for line in lines {
                let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { continue }
                let key = parts[0].lowercased()
                if key.hasPrefix("file"), let i = Int(key.dropFirst(4)) { files[i] = parts[1] }
                else if key.hasPrefix("title"), let i = Int(key.dropFirst(5)) { titles[i] = parts[1] }
            }
            for i in files.keys.sorted() { entries.append((titles[i] ?? "", "", files[i]!, false, "", "")) }
        } else {
            var title = "", group = "", playlistGroup = "", radio = false, logo = "", language = ""
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
                    func attribute(_ name: String) -> String {
                        guard let range = line.range(of: name + "=\"", options: .caseInsensitive) else { return "" }
                        return String(line[range.upperBound...].prefix { $0 != "\"" }.prefix(2000))
                    }
                    logo = attribute("tvg-logo"); language = attribute("tvg-language")
                    // Lists that mix radio into a TV playlist say so with radio="true" or tvg-type="radio".
                    let lower = line.lowercased()
                    radio = lower.contains("radio=\"true\"") || lower.contains("tvg-type=\"radio\"")
                } else if !line.hasPrefix("#") { entries.append((title, group, line, radio, logo, language)); title = ""; group = ""; radio = false; logo = ""; language = "" }
            }
        }
        var seen = Set<String>()
        return entries.prefix(maximumEntries).compactMap { entry in
            guard let address = URL(string: entry.address, relativeTo: base)?.absoluteURL, let valid = try? StreamAddress.parse(address.absoluteString),
                  RadioListing.isViable(name: entry.title, address: valid), reject?(entry.title, entry.group, valid) != true,
                  seen.insert(DiscoveryIndex.matchKey(valid.absoluteString)).inserted else { return nil }
            let ext = valid.pathExtension.lowercased()
            let codec = ["mp3": "MP3", "aac": "AAC", "ogg": "OGG", "opus": "OPUS", "m3u8": "HLS"][ext] ?? ""
            let name = String(entry.title.trimmingCharacters(in: .whitespaces).prefix(300))
            // In a TV list, a stream that is only audio (an audio file type, or marked as radio) is a radio station, not a channel.
            let audioOnly = video && (entry.radio || ["mp3", "aac", "aacp", "ogg", "oga", "opus", "m4a", "flac"].contains(ext))
            var row = RadioListing(id: UUID.stable("list:\(sourceID):\(valid.absoluteString)").uuidString, name: name,
                                   address: valid.absoluteString, tags: String(entry.group.prefix(500)), country: "", countryCode: "", codec: video && !audioOnly ? "" : codec,
                                   bitrate: 0, votes: 0, clicks: 0, hls: ext == "m3u8", sourceName: label)
            row.video = video && !audioOnly
            row.artworkURL = (try? StreamAddress.parse(entry.logo))?.absoluteString
            row.languages = DiscoveryCatalog.languageCodes(entry.language)
            return row
        }
    }
}

/// 40media Group’s free channels. Each one is a public HLS stream (H.264 video with AAC audio), so the list is fixed.
actor FortyMediaDirectory: DirectoryBackend {
    static let channels: [RadioListing] = [
        ("ENT_Channel", "ENT Channel", "Entertainment"), ("ENT_Classics", "ENT Classic", "Classic TV"), ("ENT_Drama", "ENT Drama", "Drama"),
        ("ENT_Family", "ENT Family", "Family"), ("ENT_Life", "ENT Life", "Lifestyle"), ("ENT_Movies", "ENT Movies", "Movies"),
        ("Totalmusic", "Totalmusic", "Music"), ("Totalmusic_00s", "Totalmusic 00s", "Music, 2000s"), ("Totalmusic_80s", "Totalmusic 80s", "Music, 80s"),
        ("Totalmusic_Concerts", "Totalmusic Concerts", "Music, Concerts"), ("Totalmusic_Dance", "Totalmusic Dance", "Music, Dance")
    ].map { path, title, tags in
        var row = RadioListing(id: UUID.stable("40media:" + path).uuidString, name: title,
                               address: "https://cdn.40mediagroup.com/live/c7eds/\(path)/SA_LIVE_hls_enc/master.m3u8", tags: tags, country: "", countryCode: "",
                               codec: "", bitrate: 0, votes: 0, clicks: 0, hls: true, sourceName: "40media Group")
        row.video = true; row.homepage = "https://www.40mediagroup.com/canales/"
        return row
    }
    func search(_ query: DirectoryQuery, refresh: Bool) async throws -> DirectoryPage {
        try Task.checkCancellation()
        return DirectoryFilter.page(Self.channels, query: query)
    }
}

/// What Internet TV listings must pass before they are shown. A video player can be pointed at anything, so this is deliberately strict:
/// it errs toward hiding a channel.
enum TVSafety {
    /// Which checks apply. Both are on unless the user turns them off in Preferences ▸ Internet TV.
    struct Settings: Equatable {
        var hideAdult = true
        var hideUnreliable = true
        var key: String { "\(hideAdult ? 1 : 0)\(hideUnreliable ? 1 : 0)" }
    }
    private static let adult = try! NSRegularExpression(pattern: #"(?i)(?<![a-z])(xxx|porn\w*|sex\w*|erotic\w*|nsfw|hentai|playboy|penthouse|hustler|brazzers|naked|nude|stripper\w*|fetish|bdsm|milf|18\+|adults? only|adult (?!swim))"#)
    private static let unreliable = ["geo-blocked", "not 24/7"]

    static func rejects(title: String, group: String, address: URL, settings: Settings) -> Bool { !allows(title: title, group: group, address: address, settings: settings) }

    static func allows(title: String, group: String, address: URL, settings: Settings = Settings()) -> Bool {
        if settings.hideAdult {
            for text in [title, group] where adult.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil { return false }
        }
        if settings.hideUnreliable {
            let lower = title.lowercased()
            if unreliable.contains(where: lower.contains) { return false }
            guard let host = address.host?.lowercased() else { return false }
            // A bare IP address is not a channel operator that can be identified or asked to take a stream down.
            if host.contains(":") || host.split(separator: ".").allSatisfy({ Int($0) != nil }) { return false }
        }
        return true
    }
}

extension Library.State {
    var tvSafety: TVSafety.Settings { TVSafety.Settings(hideAdult: tvHideAdult != false, hideUnreliable: tvHideUnreliable != false) }
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
#if os(macOS)
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
#else
    // iOS can't launch /usr/bin/unzip, so this source is left out of `DirectorySource.defaults` there.
    private static func unzip(_ arguments: [String], limit: Int) throws -> Data {
        throw RadioError.message("The curated archive can’t be read on this device.")
    }
#endif
}

/// rrradio.org's published catalog (MIT). Its file is mostly a copy of Radio Browser, so only the entries rrradio has checked itself are listed.
actor RrradioDirectory: DirectoryBackend {
    private var cache: (Date, [RadioListing])?
    func trim() async { if cache.idle { cache = nil } }
    func release() async { cache = nil }
    func search(_ query: DirectoryQuery, refresh: Bool) async throws -> DirectoryPage {
        try Task.checkCancellation()
        let cached = !refresh && cache.map { Date().timeIntervalSince($0.0) < 600 } == true
        if !cached {
            let data = try await DirectoryFetch.data(URL(string: DirectorySource.rrradio.url!)!, limit: 25_165_824)
            let rows = try Self.decode(data)
            guard !rows.isEmpty else { throw RadioError.message("rrradio returned no stations.") }
            cache = (Date(), rows)
        }
        var page = DirectoryFilter.page(cache?.1 ?? [], query: query); page.cached = cached; return page
    }
    private struct Catalog: Decodable { var stations: [Entry] }
    private struct Entry: Decodable {
        var id: String, name: String, streamUrl: String
        var homepage: String?, country: String?, codec: String?, status: String?
        var tags: [String]?, bitrate: Int?
    }
    static func decode(_ data: Data) throws -> [RadioListing] {
        let entries = try JSONDecoder().decode(Catalog.self, from: data).stations
        var seen = Set<String>()
        return entries.compactMap { entry in
            guard entry.status == "working" || entry.status == "icy-only", let url = try? StreamAddress.parse(entry.streamUrl),
                  RadioListing.isViable(name: entry.name, address: url), seen.insert(url.absoluteString).inserted else { return nil }
            let code = (entry.country ?? "").uppercased()
            var row = RadioListing(id: UUID.stable("rrradio:" + entry.id).uuidString, name: String(entry.name.prefix(300)), address: url.absoluteString,
                                   tags: String((entry.tags ?? []).joined(separator: ", ").prefix(500)), country: code.count == 2 ? (Locale.current.localizedString(forRegionCode: code) ?? code) : "",
                                   countryCode: code.count == 2 ? code : "", codec: (entry.codec ?? "").uppercased(), bitrate: max(0, entry.bitrate ?? 0), votes: 0, clicks: 0,
                                   hls: url.pathExtension.lowercased() == "m3u8", sourceName: "rrradio")
            row.homepage = entry.homepage.flatMap { try? StreamAddress.parse($0).absoluteString } ?? ""
            return row
        }
    }
}

/// Only explicit local imports create this adapter. No executable directives or relative local media paths.
actor LocalPlaylistDirectory: DirectoryBackend {
    let url: URL, label: String, sourceID: String
    let video: Bool
    init(url: URL, label: String, sourceID: String, video: Bool) { self.url = url; self.label = label; self.sourceID = sourceID; self.video = video }
    func search(_ query: DirectoryQuery, refresh: Bool) async throws -> DirectoryPage {
        let rows = try Self.read(url: url, label: label, sourceID: sourceID, video: video)
        return DirectoryFilter.page(rows, query: query)
    }
    static func read(url: URL, label: String, sourceID: String, video: Bool) throws -> [RadioListing] {
        guard url.isFileURL, let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 2_097_152 else { throw RadioError.message("Local playlists must be at most 2 MiB.") }
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        let data = try handle.read(upToCount: 2_097_153) ?? Data()
        guard data.count <= 2_097_152, let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { throw RadioError.message("This playlist cannot be read.") }
        guard !text.contains("#EXT-X-") else { throw RadioError.message("This is an HLS stream manifest. Use Open URL with its original stream address instead.") }
        return Array(StationListDirectory.parse(text, base: url, label: label, sourceID: sourceID, video: video).prefix(5000))
    }
}
