import Foundation

func checkDiscovery(at root: URL) throws {
    func listing(_ name: String, _ tag: String, _ endpoint: String, id: String? = nil) -> RadioListing {
        RadioListing(id: id ?? endpoint, name: name, address: endpoint, tags: tag, country: "France", countryCode: "FR", codec: "MP3", bitrate: 128, votes: 0, clicks: 0, hls: false, sourceName: "Fixture")
    }
    let url = root.appendingPathComponent("discovery.sqlite")
    let index = try DiscoveryIndex(url: url)
    var jazz = listing("Café Jazz", "jazz", "https://radio.example/jazz?token=a")
    jazz.video = true; jazz.directoryID = UUID().uuidString
    let ambient = listing("Quiet Space", "ambient", "https://other.example/live")
    try index.ingest([jazz, ambient], source: "one", name: "One")
    try check(index.records(text: "cafe", sources: ["one"]).first?.restored.name == "Café Jazz", "Discovery FTS matches case and accents")
    try check(index.records(text: "France jazz", sources: ["one"]).count == 1, "Discovery FTS combines country and genre tokens")
    try check(index.records(text: "\" OR *", sources: ["one"]).isEmpty, "Discovery search escapes FTS operators")
    try check(index.records(sources: ["disabled"]).isEmpty, "Disabled-source records never enter discovery")
    try check(index.records(text: "jazz", sources: ["one"]).first?.restored.video == true, "Index retains TV classification")
    try check(index.records(text: "jazz", sources: ["one"]).first?.restored.directoryID == jazz.directoryID, "Index retains directory identity")
    let reopened = try DiscoveryIndex(url: url)
    try check(reopened.records(sources: ["one"]).count == 2, "Discovery survives reopening without network access")
    var changed = ambient; changed.name = "Soft Orbit"
    try index.ingest([changed], source: "one", name: "One")
    try check(index.records(text: "Quiet", sources: ["one"]).isEmpty && index.records(text: "Orbit", sources: ["one"]).count == 1, "Updating a listing replaces old search terms")
    try index.ingest([ambient], source: "two", name: "Two")
    try check(index.records(sources: ["one", "two"]).count == 3, "Overlapping endpoints preserve both source listings")
    try check(DiscoveryIndex.endpointKey("HTTPS://RADIO.EXAMPLE:443/live?token=a") == "https://radio.example/live?token=a", "Conservative endpoint identity normalizes host and port")
    try check(DiscoveryIndex.endpointKey("https://radio.example/live?token=a") != DiscoveryIndex.endpointKey("https://radio.example/live?token=b"), "Signed URL query strings stay distinct")
    try index.retainSources(["two"])
    try check(index.records(sources: ["one", "two"]).count == 1, "Removing a source removes only its provenance")
    try index.clear()
    try check(index.records(sources: ["two"]).isEmpty, "Clear discovery removes indexed metadata")
    for name in ["Adult Jazz", "Explicit Rock", "Uncensored Pop", "News Jazz", "Casino Lounge", "Sexual Soul", "Hate Talk", "Violent Metal"] {
        try check(!DiscoverySafety.allows(listing(name, "jazz", "https://radio.example/live")), "Discover excludes sensitive metadata: \(name)")
    }
    try check(!DiscoverySafety.allows(listing("Unknown", "", "https://radio.example/live")), "Unclassified stations are withheld from recommendations")
    try check(!DiscoverySafety.allows(listing("Jazz", "jazz", "https://radio.example/%70orn/live")), "Encoded sensitive stream paths are excluded")
    try check(DiscoverySafety.allows(ambient), "Ordinary music stations remain eligible")
    let rows = (0..<36).map { i in listing("Station \(i)", DiscoverySafety.genres[i % DiscoverySafety.genres.count], "https://host\(i).example/live") }
    try index.ingest(rows, source: "seed", name: "Seed")
    let records = try index.records(sources: ["seed"])
    func feed(recent: [Station] = [], interests: [String] = [], dismissed: Set<String> = [], personalizes: Bool = true) -> DiscoveryFeed {
        DiscoveryRecommendations.build(records: records, recent: recent, favorites: [], interests: interests, dismissed: dismissed, personalizes: personalizes, video: false, day: 123)
    }
    let cold = feed()
    try check(!cold.shelves.isEmpty && cold.basis.contains("no listening history"), "Cold start produces a varied fallback without history")
    try check(cold.shelves.flatMap(\.picks).map { $0.listing.id } == feed().shelves.flatMap(\.picks).map { $0.listing.id }, "Exploration is deterministic within a day")
    let picked = feed(interests: ["jazz"])
    try check(picked.interests.first == "jazz", "Explicit interests lead recommendation affinity")
    let hidden = Set(rows.map { DiscoveryIndex.endpointKey($0.address) })
    try check(feed(dismissed: hidden).shelves.isEmpty, "Dismissals remove endpoints from every shelf")
    let history = rows.prefix(6).map(\.station)
    try check(feed(recent: history).basis.contains("recent listening"), "Successful-playback history personalizes discovery")
    try check(feed(recent: history, personalizes: false).basis.contains("no listening history"), "History opt-out actually removes history influence")
    let all = cold.shelves.flatMap(\.picks).map { $0.listing.address }
    try check(Set(all).count == all.count, "Shelves do not repeat endpoints")
    let conflict = listing("Explicit Ambient", "ambient", rows[0].address)
    try index.ingest([conflict], source: "conflict", name: "Conflict")
    let conflicted = DiscoveryRecommendations.build(records: try index.records(sources: ["seed", "conflict"]), recent: [], favorites: [], interests: [], dismissed: [], personalizes: true, video: false)
    try check(!conflicted.shelves.flatMap(\.picks).contains { $0.listing.address == conflict.address }, "Conflicting sensitive provenance excludes an endpoint everywhere")
    let playlist = root.appendingPathComponent("import.m3u")
    try Data("#EXTM3U\n#EXTINF:-1 group-title=\"Jazz\",Local Jazz\nhttps://radio.example/live\nfile:///etc/passwd\n".utf8).write(to: playlist)
    let imported = try LocalPlaylistDirectory.read(url: playlist, label: "Local", sourceID: "local", video: false)
    try check(imported.count == 1 && imported[0].tags.lowercased().contains("jazz"), "Local import retains genre and rejects local media paths")
    try Data("#EXTM3U\n#EXT-X-TARGETDURATION:6\nsegment.ts".utf8).write(to: playlist)
    try rejects("Downloaded HLS manifests cannot become station catalogs") { _ = try LocalPlaylistDirectory.read(url: playlist, label: "Local", sourceID: "local", video: false) }
    try check(!StreamProbe.automaticProbingSupported, "Discovery never automatically probes untrusted stream destinations")
    let legacy = try JSONDecoder().decode(Library.State.self, from: Data(#"{"favorites":[],"volume":0.5,"scale":2}"#.utf8))
    try check(legacy.discoveryInterests == nil, "Legacy library settings decode with discovery defaults")
}
