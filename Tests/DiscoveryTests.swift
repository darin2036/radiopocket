import Foundation
import AppKit

func checkDiscovery(at root: URL) throws {
    func listing(_ name: String, _ tag: String, _ endpoint: String, id: String? = nil) -> RadioListing {
        RadioListing(id: id ?? endpoint, name: name, address: endpoint, tags: tag, country: "France", countryCode: "FR", codec: "MP3", bitrate: 192, votes: 0, clicks: 0, hls: false, sourceName: "Fixture")
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
    try check(DiscoveryIndex.matchKey("http://Radio.Example:80/live/") == DiscoveryIndex.matchKey("https://radio.example/live"), "Directories listing the same stream over http, https or with a trailing slash match")
    try check(DiscoveryIndex.matchKey("https://radio.example/live?token=a") != DiscoveryIndex.matchKey("https://radio.example/live?token=b"), "Match identity keeps distinct query strings apart")
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
    let qualityRows = [0, 48, 64, 128, 192, 320].enumerated().map { position, bitrate in
        var row = listing("Quality Jazz \(position)", "jazz", "https://quality\(position).example/live")
        row.bitrate = bitrate
        return row
    }
    try index.ingest(qualityRows, source: "quality", name: "Quality")
    let qualityRecords = try index.records(sources: ["quality"])
    let qualityFeed = DiscoveryRecommendations.build(records: qualityRecords, recent: qualityRows.map(\.station), favorites: qualityRows.map(\.station), interests: ["jazz"], dismissed: [], personalizes: true, video: false, feedback: Dictionary(uniqueKeysWithValues: qualityRows.map { ("url:" + DiscoveryIndex.endpointKey($0.address), 1) }))
    let qualityPicks = qualityFeed.shelves.flatMap(\.picks)
    try check(Set(qualityPicks.map { $0.listing.quality }) == Set([4, 5]), "Discovery includes four and five stars, excluding unknown and lower quality even with favorites and positive feedback")
    var tvRows = [listing("Evening Movies", "Movies;General", "https://tv1.example/live.m3u8"), listing("Cartoon Hour", "Kids;Animation", "https://tv2.example/live.m3u8"), listing("Cartoon Hour FR", "Kids;Animation", "https://tv3.example/live.m3u8"), listing("Mystery Channel", "", "https://tv4.example/live.m3u8")]
    for i in tvRows.indices { tvRows[i].video = true; tvRows[i].bitrate = 0; tvRows[i].codec = ""; tvRows[i].languages = i == 3 ? nil : [i == 2 ? "fr" : "en"] }
    try index.ingest(tvRows, source: "tv", name: "TV")
    let tvRecords = try index.records(sources: ["tv"])
    let tvNames = Set(DiscoveryRecommendations.build(records: tvRecords, recent: [], favorites: [], interests: ["kids"], dismissed: [], personalizes: false, video: true, languages: ["en"], includeUnknownLanguage: false).shelves.flatMap(\.picks).map(\.listing.name))
    try check(tvNames == Set(["Evening Movies", "Cartoon Hour"]) && DiscoveryCatalog.languageHints("Iqra Bangla") == ["bn"] && DiscoveryCatalog.foreignScript("تلفزيون", wanted: ["en"]) && !DiscoveryCatalog.foreignScript("Canal Uno", wanted: ["en"]), "TV discovery matches categories and language, rules out other languages, and keeps channels with no language")
    let lowRecords = qualityRecords.filter { $0.restored.quality < 4 }
    let lowFeed = DiscoveryRecommendations.build(records: lowRecords, recent: [], favorites: [], interests: [], dismissed: [], personalizes: false, video: false)
    try check(lowFeed.shelves.isEmpty, "Cold-start discovery never relaxes the quality floor to fill empty shelves")
    let cold = feed()
    try check(!cold.shelves.isEmpty && cold.basis.contains("no listening history"), "Cold start produces a varied fallback without history")
    try check(cold.shelves.flatMap(\.picks).map { $0.listing.id } == feed().shelves.flatMap(\.picks).map { $0.listing.id }, "Exploration is deterministic within a day")
    let picked = feed(interests: ["jazz"])
    try check(picked.interests.first == "jazz", "Explicit interests lead recommendation affinity")
    let reasonRow = listing("Electronic Music", "electronic music", "https://reason.example/live")
    func reason(explicit: Set<String> = [], recent: Set<String> = [], favorites: Set<String> = []) -> String {
        DiscoveryRecommendations.recommendationReason(for: reasonRow, rankedGenres: ["music", "electronic"], explicit: explicit, recent: recent, favorites: favorites, vote: 0)
    }
    try check(reason(explicit: ["music", "electronic"]) == "Electronic that matches your chosen interests", "Reasons prefer a specific matching genre over generic music")
    try check(reason(recent: ["electronic"]).contains("recent listening"), "Reasons identify actual history signals")
    try check(reason(favorites: ["electronic"]).contains("favorites"), "Reasons identify actual favorite signals")
    try check(reason().contains("explore") && !reason().contains("recent listening"), "Exploration reasons do not invent listening history")
    let genericRow = listing("Music Radio", "music", "https://generic.example/live")
    try check(DiscoveryRecommendations.recommendationReason(for: genericRow, rankedGenres: ["music"], explicit: ["music"], recent: [], favorites: [], vote: 0).contains("stream quality"), "Generic metadata falls back to the known quality signal")
    let hidden = Set(rows.map { DiscoveryIndex.endpointKey($0.address) })
    try check(!feed(dismissed: hidden).shelves.isEmpty && feed(dismissed: hidden).shelves.flatMap(\.picks).allSatisfy { $0.feedback == -1 }, "Legacy hidden stations become lower-priority recommendations instead of exclusions")
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
    try check(!StreamProbe.automaticProbingSupported, "Legacy browser probing stays disabled; discovery uses its separate pinned transport")
    let iptv = "#EXTM3U\n#EXTINF:-1 tvg-id=\"DasErste.de@SD\" group-title=\"General\",Das Erste\nhttps://tv.example/erste.m3u8\n#EXTINF:-1 tvg-id=\"Fox.us@HD\" group-title=\"General\",Fox\nhttps://tv.example/fox.m3u8\n#EXTINF:-1 tvg-id=\"Rai.it@SD\" group-title=\"General\",Rai Espanol\nhttps://tv.example/rai.m3u8\n#EXTINF:-1 tvg-id=\"Lost\" group-title=\"General\",Lost\nhttps://tv.example/lost.m3u8"
    let iptvRows = StationListDirectory.parse(iptv, base: URL(string: "https://tv.example/list.m3u")!, label: "TV", sourceID: "tv", video: true)
    func iptvRow(_ name: String) -> RadioListing? { iptvRows.first { $0.name == name } }
    try check(iptvRow("Das Erste")?.countryCode == "DE" && iptvRow("Das Erste")?.languages == ["de"] && iptvRow("Fox")?.languages == ["en", "es"] && iptvRow("Rai Espanol")?.languages == ["es"] && iptvRow("Lost")?.languages?.isEmpty != false && DiscoveryCatalog.region(country: "", channelID: "BBCOne.uk@SD") == "GB", "TV channels take country and language from the tvg-id suffix, with a name that states a language winning")
    var germanTV = DirectoryQuery(); germanTV.video = true; germanTV.countryCode = "DE"; germanTV.supportedOnly = false
    try check(DirectoryFilter.page(iptvRows, query: germanTV).stations.map(\.name) == ["Das Erste"], "The Country filter narrows TV channels now that they carry a country")
    var spanishTV = germanTV; spanishTV.countryCode = ""; spanishTV.language = "es"
    var germanTVLanguage = germanTV; germanTVLanguage.language = "de"
    try check(Set(DirectoryFilter.page(iptvRows, query: spanishTV).stations.map(\.name)) == Set(["Fox", "Rai Espanol"]) && DirectoryFilter.page(iptvRows, query: germanTVLanguage).stations.count == 1 && StationCache(directory: FileManager.default.temporaryDirectory).key(for: spanishTV, sources: ["tv"]) != StationCache(directory: FileManager.default.temporaryDirectory).key(for: germanTV, sources: ["tv"]), "The TV language filter keeps matching channels and has its own cache entry")
    try check(DiscoveryCatalog.genres.count >= 60 && DiscoveryCatalog.languages.count >= 30, "Discovery offers broad genre and language vocabularies")
    try check(DiscoveryCatalog.matches("lofi, deep-house, hip-hop, drum & bass").isSuperset(of: ["lo-fi", "deep house", "hip hop", "drum and bass"]), "Genre aliases and multiword styles normalize consistently")
    try check(!DiscoveryCatalog.matches("rockabilly").contains("rock"), "Genre matching does not match arbitrary substrings")
    try check(DiscoveryCatalog.tvMatches("Movies;General Evening films").contains("movies") && DiscoveryCatalog.tvMatches("Kids cartoons").isSuperset(of: ["kids", "animation"]), "TV categories match channel group names")
    try check(DiscoveryCatalog.systemLanguages(["nb-NO", "fr-CA", "xx", "en-US", "fr-FR"]) == ["no", "fr", "en"], "Mac languages map to Discover language codes in order")

    let vibe = DiscoveryCatalog.interpretVibes("Something with High BPM")
    try check(vibe.genres.contains("techno") && vibe.genres.contains("house") && vibe.remainder.isEmpty, "Descriptive searches like high BPM map to electronic genres")
    try check(DiscoveryCatalog.interpretVibes("bbc world").genres.isEmpty && DiscoveryCatalog.interpretVibes("bbc world").remainder == "bbc world", "Plain station-name searches stay literal")
    try check(Set(DiscoveryCatalog.languageCodes("fre,eng,Deutsch,espanol")) == Set(["fr", "en", "de", "es"]), "Directory language names and ISO variants normalize to shared codes")
    var detailed = listing("Deep House Radio", "deep house", "https://radio.example/house", id: UUID().uuidString)
    detailed.homepage = "https://radio.example/"; detailed.artworkURL = "https://radio.example/logo.png"; detailed.languages = ["en", "fr"]
    let decoded = try JSONDecoder().decode(RadioListing.self, from: JSONEncoder().encode(detailed))
    try check(decoded.artworkURL == detailed.artworkURL && Set(decoded.languages ?? []) == Set(["en", "fr"]), "Directory values preserve artwork URL and language metadata")
    try index.ingest([detailed], source: "details", name: "Details")
    let storedDetails = try index.records(sources: ["details"])
    try check(storedDetails.first?.restored.artworkURL == detailed.artworkURL && storedDetails.first?.restored.languages == ["en", "fr"], "Index persists metadata URLs and languages without image bytes")
    func languageFeed(_ language: String, unknown: Bool, records: [DiscoveryIndex.Record]) -> DiscoveryFeed {
        DiscoveryRecommendations.build(records: records, recent: [], favorites: [], interests: [], dismissed: [], personalizes: false, video: false, languages: [language], includeUnknownLanguage: unknown)
    }
    try check(!languageFeed("fr", unknown: false, records: storedDetails).shelves.isEmpty, "Published matching languages qualify for recommendations")
    try check(languageFeed("ja", unknown: true, records: storedDetails).shelves.isEmpty, "Known nonmatching languages do not bypass a language preference")
    try check(languageFeed("fr", unknown: false, records: records).shelves.isEmpty && !languageFeed("fr", unknown: true, records: records).shelves.isEmpty, "Unknown-language preference has an explicit effective fallback")
    var state = Library.State(); state.discoveryInterests = ["ambient"]; state.discoveryLanguages = ["fr"]; state.discoveryArtwork = false
    var prefs = DiscoveryPreferences(state: state); prefs.genres = ["deep house", "synthwave"]; prefs.languages = ["ja"]; prefs.apply(to: &state)
    let restoredPreferences = DiscoveryPreferences(state: try JSONDecoder().decode(Library.State.self, from: JSONEncoder().encode(state)))
    try check(restoredPreferences.genres == prefs.genres && restoredPreferences.languages == ["ja"] && !restoredPreferences.showArtwork, "Mix preferences survive persistence and preserve the artwork opt-out")
    let artworkPlaylist = "#EXTM3U\n#EXTINF:-1 tvg-logo=\"https://radio.example/logo.png\" tvg-language=\"French\" group-title=\"Jazz\",French Jazz\nhttps://radio.example/live"
    let withArtwork = StationListDirectory.parse(artworkPlaylist, base: URL(string: "https://radio.example/list.m3u")!, label: "Mine", sourceID: "mine")
    try check(withArtwork.first?.artworkURL == "https://radio.example/logo.png" && withArtwork.first?.languages == ["fr"], "Imported playlist artwork and language attributes are retained")
    try check(StationArtwork.publicURL("https://images.example.org/logo.png") != nil, "Public metadata artwork URLs are accepted")
    for address in ["file:///tmp/logo.png", "http://localhost/logo.png", "http://192.168.1.1/logo.png", "http://printer.local/logo.png", "https://user:secret@images.example.org/a.png", "https://images.example.org:9000/a.png"] {
        try check(StationArtwork.publicURL(address) == nil, "Artwork rejects unsafe destination: \(address)")
    }
    try check(StationArtwork.website("javascript:alert(1)") == nil && StationArtwork.website("https://radio.example/") != nil, "Station websites require an explicit HTTP(S) link")
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 32, bitsPerPixel: 32)!
    let fixturePNG = bitmap.representation(using: .png, properties: [:])!
    try check(StationArtwork.thumbnail(fixturePNG) != nil, "Artwork decodes a bounded thumbnail entirely from memory")
    try check(StationArtwork.thumbnail(Data("<svg/>".utf8)) == nil && StationArtwork.thumbnail(Data(count: StationArtwork.maximumBytes + 1)) == nil, "Malformed and oversized artwork are ignored")
    var voteState = Library.State()
    DiscoveryFeedback.toggle(1, station: detailed, state: &voteState)
    try check(DiscoveryFeedback.vote(for: detailed, in: voteState.discoveryFeedback ?? [:]) == 1, "Thumbs up records local station preference")
    DiscoveryFeedback.toggle(-1, station: detailed, state: &voteState)
    try check(DiscoveryFeedback.vote(for: detailed, in: voteState.discoveryFeedback ?? [:]) == -1, "Opposite feedback replaces the previous vote")
    DiscoveryFeedback.toggle(-1, station: detailed, state: &voteState)
    try check(DiscoveryFeedback.vote(for: detailed, in: voteState.discoveryFeedback ?? [:]) == 0, "Clicking a selected thumb clears the vote")
    let negative = DiscoveryRanking.score(relevance: 12, quality: 4, variation: 0.5, feedback: -1)
    let neutral = DiscoveryRanking.score(relevance: 12, quality: 4, variation: 0.5, feedback: 0)
    let positive = DiscoveryRanking.score(relevance: 12, quality: 4, variation: 0.5, feedback: 1)
    try check(negative < neutral && positive > neutral, "Feedback adjusts ranking without changing eligibility")
    DiscoveryFeedback.toggle(-1, station: rows[0], state: &voteState)
    let ratedFeed = DiscoveryRecommendations.build(records: records, recent: [], favorites: [], interests: [], dismissed: [], personalizes: false, video: false, feedback: voteState.discoveryFeedback ?? [:])
    try check(ratedFeed.shelves.last?.picks.contains { $0.listing.address == rows[0].address && $0.feedback == -1 } == true, "Thumbs-down station remains discoverable farther down the feed")
    let persistedVotes = try JSONDecoder().decode(Library.State.self, from: JSONEncoder().encode(voteState))
    try check(persistedVotes.discoveryFeedback == voteState.discoveryFeedback, "Station preferences persist locally across launches")
    var oldVotes = Library.State(); oldVotes.discoveryDismissed = [DiscoveryIndex.endpointKey(detailed.address)]
    DiscoveryFeedback.toggle(-1, station: detailed, state: &oldVotes)
    try check(DiscoveryFeedback.vote(for: detailed, in: oldVotes.discoveryFeedback ?? [:], legacy: Set(oldVotes.discoveryDismissed ?? [])) == 0, "Legacy downvote can be cleared with the same thumb")
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: -8 * 3600)!
    func moment(_ day: Int, _ hour: Int) -> MoodCuration.Moment {
        MoodCuration.Moment(date: calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour))!, calendar: calendar)
    }
    let monday = moment(2, 8), saturday = moment(7, 8)
    try check(!monday.weekend && saturday.weekend, "Moods use the local calendar's weekend")
    try check(MoodCuration.themes(for: monday).first?.title != MoodCuration.themes(for: saturday).first?.title, "Weekend mornings have their own curation")
    try check(moment(2, 4).period == "Late night" && moment(2, 5).period == "Morning" && moment(2, 12).period == "Afternoon" && moment(2, 17).period == "Evening" && moment(2, 22).period == "Late night", "Mood periods change at local boundaries")
    try check(moment(2, 23).key != moment(3, 0).key, "Mood rotation changes at local midnight")
    let themes = MoodCuration.themes(for: monday)
    let mood = MoodCuration.build(records: records, state: Library.State(), moment: monday, themes: themes)
    let moodAddresses = mood.shelves.flatMap(\.picks).map { $0.listing.address }
    try check(!moodAddresses.isEmpty && Set(moodAddresses).count == moodAddresses.count, "Mood shelves contain real, nonduplicate station endpoints")
    try check(Set(moodAddresses).isSubset(of: Set(rows.map(\.address))), "Mood curation never invents endpoints")
    try check(moodAddresses == MoodCuration.build(records: records, state: Library.State(), moment: monday, themes: themes).shelves.flatMap(\.picks).map { $0.listing.address }, "Mood rotation is stable within a local day")
    try check(MoodCuration.build(records: [], state: Library.State(), moment: monday, themes: themes).shelves.isEmpty, "No installed listings means no fabricated mood stations")
    var moodState = Library.State(); moodState.discoveryLanguages = ["ja"]; moodState.discoveryIncludeUnknownLanguage = false
    try check(MoodCuration.build(records: records, state: moodState, moment: monday, themes: themes).shelves.isEmpty, "Moods preserve strict language preferences")
    moodState = Library.State(); moodState.discoveryDismissed = rows.map { DiscoveryIndex.endpointKey($0.address) }
    try check(MoodCuration.build(records: records, state: moodState, moment: monday, themes: themes).shelves.isEmpty, "Negative feedback keeps stations out of automatic mood picks")
    try check(MoodWeather.kind(code: 61) == .rain && MoodWeather.kind(code: 95) == .rain && MoodWeather.kind(code: 71) == .snow && MoodWeather.kind(code: 3) == .cloudy && MoodWeather.kind(code: 0) == .clear, "Weather codes distinguish rain, snow, clouds and clear skies")
    try check(MoodWeather.kind(code: -1) == nil && MoodWeather.kind(code: 500) == nil, "Unknown weather never invents current conditions")
    try check(MoodCuration.themes(for: monday, weather: .rain).first?.title == "A rainy-day retreat", "Detected rain adds a rainy-day mood")
    try check(!MoodCuration.themes(for: monday).contains { $0.title.contains("rainy") }, "Unavailable weather keeps time-based moods without assuming rain")
    var weatherState = Library.State(); weatherState.moodCity = MoodCity(name: "Seattle, Washington, United States", latitude: 47.61, longitude: -122.33)
    let restoredWeather = try JSONDecoder().decode(Library.State.self, from: JSONEncoder().encode(weatherState))
    try check(restoredWeather.moodCity == weatherState.moodCity, "Optional weather city persists locally")
    try check(MoodCity(name: "Valid", latitude: 0, longitude: 0).valid && !MoodCity(name: "Invalid", latitude: 91, longitude: 0).valid && !MoodCity(name: "Invalid", latitude: 0, longitude: .infinity).valid, "Weather requests require finite coordinates in range")
    let planContext = MoodPlanning.context(records: records, state: Library.State(), moment: monday, weather: .rain)
    let reorderedContext = MoodPlanning.context(records: records.reversed(), state: Library.State(), moment: monday, weather: .rain)
    try check(planContext.prompt == reorderedContext.prompt && planContext.cacheKey == reorderedContext.cacheKey, "Mood prompts are stable regardless of directory record order")
    let dryContext = MoodPlanning.context(records: records, state: Library.State(), moment: monday, weather: nil)
    try check(planContext.cacheKey != dryContext.cacheKey && dryContext.prompt.contains("unknown; do not infer"), "Weather changes invalidate the mood plan without inventing unknown conditions")
    let eveningContext = MoodPlanning.context(records: records, state: Library.State(), moment: moment(2, 18), weather: .rain)
    try check(planContext.cacheKey != eveningContext.cacheKey, "A new time period gets a new contextual prompt")
    let christmas = MoodCuration.Moment(date: calendar.date(from: DateComponents(year: 2026, month: 12, day: 25, hour: 18))!, calendar: calendar)
    try check(christmas.occasion == "Christmas Day" && monday.occasion == nil, "Known calendar occasions are explicit and ordinary days have none")
    try check(christmas.greeting(name: "Darin") == "Good evening, Darin" && monday.greeting() == "Good morning", "Greeting uses the local period and optional name")
    let fallbackPlan = MoodPlanning.fallback(planContext)
    let plannedFeed = MoodPlanning.build(records: records, state: Library.State(), context: planContext, plan: fallbackPlan)
    try check(!plannedFeed.moodGroups.isEmpty && plannedFeed.moodGroups.allSatisfy { !$0.collections.isEmpty }, "Mood browser has activities with playable station collections")
    try check(plannedFeed.shelves.flatMap(\.picks).allSatisfy { pick in rows.contains { $0.address == pick.listing.address } }, "Every planned collection resolves to an actual directory endpoint")
    let allowedGenre = planContext.genreCounts.keys.sorted().first!
    let validPlan = MoodPlan(activities: [.init(title: "Rainy-day retreat", detail: "A softer soundtrack for the rain.", artwork: "rain", collections: [.init(title: "Window seat", genres: [allowedGenre])])])
    let validatedPlan = try validPlan.validated(available: Set(planContext.genreCounts.keys))
    try check(validatedPlan == validPlan, "Validated AI plans preserve activity and collection structure")
    var badPlan = validPlan; badPlan.activities[0].collections[0].genres = ["invented-genre"]
    try rejects("AI cannot invent available genres") { _ = try badPlan.validated(available: Set(planContext.genreCounts.keys)) }
    badPlan = validPlan; badPlan.activities[0].title = "https://invented.example/live"
    try rejects("AI collection plans cannot smuggle stream URLs into titles") { _ = try badPlan.validated(available: Set(planContext.genreCounts.keys)) }
    var conflictingPlan = validPlan
    conflictingPlan.activities.append(.init(title: "Weekend pause", detail: "Slow down this weekend.", artwork: "focus", collections: validPlan.activities[0].collections))
    let contextualPlan = try MoodPlanning.validate(conflictingPlan, context: planContext)
    try check(contextualPlan.activities.count == 1 && contextualPlan.activities.first?.title == "Rainy-day retreat", "Weekday curation drops contradictory weekend suggestions")
    try rejects("Unknown weather cannot produce a detected-rain mood") { _ = try MoodPlanning.validate(validPlan, context: dryContext) }
    var greetingPlan = validPlan
    greetingPlan.greetings = ["Monday morning, amirite?", "Friday party time", "Good evening", "Snow day", String(repeating: "x", count: 61)]
    let greetingResult = try MoodPlanning.validate(greetingPlan, context: planContext)
    try check(greetingResult.greetings == ["Monday morning, amirite?"], "Greetings reject mismatched days, periods, weather and oversized copy")
    try check(MoodPlanning.greeting(moment: monday, name: "Darin", options: greetingResult.greetings) == "Monday morning, amirite?", "Validated AI greetings reach the header")
    try check(MoodPlanning.greeting(moment: monday, name: "Darin", options: []) == MoodPlanning.greeting(moment: monday, name: "Darin", options: []), "Fallback greeting stays stable across refreshes")
    var strictMoodState = Library.State(); strictMoodState.discoveryLanguages = ["ja"]; strictMoodState.discoveryIncludeUnknownLanguage = false
    try check(MoodPlanning.context(records: records, state: strictMoodState, moment: monday, weather: .rain).genreCounts.isEmpty, "AI vocabulary includes only language-eligible stations")
    let overlapRows = (0..<24).map { listing("Mood fixture \($0)", "jazz", "https://mood\($0).example/live") }
    try index.ingest(overlapRows, source: "mood-overlap", name: "Mood overlap")
    let overlapRecords = try index.records(sources: ["mood-overlap"])
    let overlapContext = MoodPlanning.context(records: overlapRecords, state: Library.State(), moment: monday, weather: nil)
    let overlapPlan = MoodPlan(activities: ["Coffee", "Dinner", "Unwind"].map { .init(title: $0, detail: "Jazz for this moment", artwork: "sun", collections: [.init(title: $0, genres: ["jazz"])]) })
    let overlapFeed = MoodPlanning.build(records: overlapRecords, state: Library.State(), context: overlapContext, plan: overlapPlan)
    let overlapEndpoints = overlapFeed.moodGroups.flatMap(\.collections).flatMap(\.picks).map { DiscoveryIndex.endpointKey($0.listing.address) }
    try check(overlapFeed.moodGroups.count == 3 && overlapEndpoints.count == 12 && Set(overlapEndpoints).count == 4, "Each mood independently keeps its four best fits, allowing appropriate overlap")
    let sparseFeed = MoodPlanning.build(records: Array(overlapRecords.prefix(2)), state: Library.State(), context: overlapContext, plan: overlapPlan)
    try check(sparseFeed.moodGroups.count == 3 && sparseFeed.moodGroups.allSatisfy { $0.collections.flatMap(\.picks).count == 2 }, "A station used by one mood remains eligible for other matching moods")
    let reversedFeed = MoodPlanning.build(records: overlapRecords.reversed(), state: Library.State(), context: overlapContext, plan: overlapPlan)
    try check(overlapEndpoints == reversedFeed.shelves.flatMap(\.picks).map { DiscoveryIndex.endpointKey($0.listing.address) }, "Mood matching remains stable across directory ordering")
    let mixedRows = (0..<12).map { listing("Style fixture \($0)", $0 < 6 ? "ambient" : "dance", "https://style\($0).example/live") }
    try index.ingest(mixedRows, source: "mood-styles", name: "Mood styles")
    let mixedRecords = try index.records(sources: ["mood-styles"])
    let mixedContext = MoodPlanning.context(records: mixedRecords, state: Library.State(), moment: monday, weather: nil)
    let mixedPlan = MoodPlan(activities: [
        .init(title: "Focus", detail: "Quiet textures", artwork: "focus", collections: [.init(title: "Ambient", genres: ["ambient"])]),
        .init(title: "Party", detail: "Upbeat rhythms", artwork: "party", collections: [.init(title: "Dance", genres: ["dance"])]),
        .init(title: "Explore", detail: "Two directions", artwork: "sun", collections: [.init(title: "Quiet", genres: ["ambient"]), .init(title: "Upbeat", genres: ["dance"])])])
    let mixedFeed = MoodPlanning.build(records: mixedRecords, state: Library.State(), context: mixedContext, plan: mixedPlan)
    try check(mixedFeed.moodGroups.count == 3 && mixedFeed.moodGroups.allSatisfy { $0.collections.flatMap(\.picks).count == 4 }, "Four-station cap applies to the entire mood, including multiple musical directions")
    try check(mixedFeed.moodGroups[0].collections.flatMap(\.picks).allSatisfy { $0.listing.tags == "ambient" } && mixedFeed.moodGroups[1].collections.flatMap(\.picks).allSatisfy { $0.listing.tags == "dance" }, "Contrasting moods select matching musical styles")
    try check(mixedFeed.moodGroups[2].collections.map { $0.picks.count } == [2, 2], "Four options represent both musical directions instead of only the first")
    let reorderedMoods = MoodPlanning.build(records: mixedRecords, state: Library.State(), context: mixedContext, plan: MoodPlan(activities: mixedPlan.activities.reversed()))
    try check(mixedFeed.moodGroups.allSatisfy { group in group.collections.flatMap(\.picks).map { $0.listing.address } == reorderedMoods.moodGroups.first { $0.title == group.title }?.collections.flatMap(\.picks).map { $0.listing.address } }, "Mood order never changes another mood's eligible stations")
    let nearby = MoodCity.approximate(name: "Nearby city", latitude: 47.61234, longitude: -122.33456)
    try check(abs(nearby.latitude - 47.6) < 0.00001 && abs(nearby.longitude + 122.35) < 0.00001 && nearby.valid, "Device location is rounded to an area before storage or weather requests")
    var firstUse = Library.State()
    try check(!DiscoveryPreferences(state: firstUse).weatherPromptHandled && firstUse.moodCity == nil, "New libraries offer weather setup without requesting location automatically")
    var weatherPrefs = DiscoveryPreferences(state: firstUse); weatherPrefs.weatherPromptHandled = true; weatherPrefs.apply(to: &firstUse)
    let skippedWeather = try JSONDecoder().decode(Library.State.self, from: JSONEncoder().encode(firstUse))
    try check(skippedWeather.moodWeatherPromptHandled == true && skippedWeather.moodCity == nil, "Skipping weather survives relaunch without enabling weather")
    weatherPrefs.moodCity = nearby
    try check(firstUse.moodCity == nil, "Weather preference drafts do not save a location until Apply")
    weatherPrefs.apply(to: &firstUse)
    try check(firstUse.moodCity == nearby, "Your mix can enable a city after first-use setup was skipped")
    weatherPrefs.moodCity = nil; weatherPrefs.apply(to: &firstUse)
    try check(firstUse.moodCity == nil && firstUse.moodWeatherPromptHandled == true, "Turning weather off does not restart the first-use introduction")
    let legacy = try JSONDecoder().decode(Library.State.self, from: Data(#"{"favorites":[],"volume":0.5,"scale":2}"#.utf8))
    try check(legacy.discoveryInterests == nil, "Legacy library settings decode with discovery defaults")
    let availabilityFile = root.appendingPathComponent("availability.json")
    let availability = DiscoveryAvailability(file: availabilityFile)
    let address = rows[0].address, key = DiscoveryIndex.endpointKey(address), now = Date()
    availability.record(address, verdict: .doubtful, now: now)
    try check(availability.snapshot(now: now)[key]?.excluded(at: now) == false, "A single doubtful failure never excludes a station")
    availability.record(address, verdict: .doubtful, now: now.addingTimeInterval(1))
    try check(availability.snapshot(now: now)[key]?.failures == 1, "Repeated immediate checks cannot multiply failure strikes")
    availability.record(address, verdict: .doubtful, now: now.addingTimeInterval(120))
    try check(availability.snapshot(now: now)[key]?.excluded(at: now.addingTimeInterval(120)) == false, "Second spaced failure remains eligible for another retry")
    availability.record(address, verdict: .doubtful, now: now.addingTimeInterval(240))
    let failed = availability.snapshot(now: now)[key]!
    try check(failed.excluded(at: now.addingTimeInterval(240)) && !failed.excluded(at: now.addingTimeInterval(2040)), "Three spaced failures cause only a temporary 30-minute exclusion")
    try check(DiscoveryAvailability(file: availabilityFile).snapshot(now: now)[key] == failed, "Availability evidence persists locally across launches")
    availability.record(address, verdict: .alive, now: now.addingTimeInterval(241))
    let goneAddress = rows[2].address, goneKey = DiscoveryIndex.endpointKey(goneAddress)
    availability.record(goneAddress, verdict: .dead, now: now)
    try check(availability.snapshot(now: now)[goneKey]?.excluded(at: now) == true && availability.snapshot(now: now)[goneKey]?.excluded(at: now.addingTimeInterval(DiscoveryAvailability.deadFor + 1)) == false, "A definitive dead link is hidden at once, then retried later")
    let verified = availability.snapshot(now: now)[key]!
    try check(verified.failures == 0 && !verified.excluded(at: now) && verified.boost(at: now.addingTimeInterval(242)) > 0, "Successful response immediately recovers a station and boosts recent verification")
    try check(verified.boost(at: now.addingTimeInterval(4000)) == 0, "Old verification loses its ranking boost")
    try check(!availability.due(address, now: now.addingTimeInterval(242)) && availability.due(address, now: now.addingTimeInterval(1141)), "Successful checks are cached for 15 minutes")
    availability.record(rows[1].address, verdict: .unknown, now: now)
    try check(availability.snapshot(now: now)[DiscoveryIndex.endpointKey(rows[1].address)]?.failures == 0, "Offline and inconclusive results add no strikes")
    let unavailableFeed = DiscoveryRecommendations.build(records: records, recent: [], favorites: [], interests: [], dismissed: [], personalizes: false, video: false, availability: [key: failed])
    try check(!unavailableFeed.shelves.flatMap(\.picks).contains { $0.listing.address == address }, "Temporarily unavailable stations are excluded across discovery shelves")
    let trusted = DiscoveryAvailability.Evidence(checked: now, verified: now, failures: 0, excludedUntil: nil)
    let trustedFeed = DiscoveryRecommendations.build(records: qualityRecords, recent: [], favorites: [], interests: [], dismissed: [], personalizes: false, video: false, availability: [DiscoveryIndex.endpointKey(qualityRows[4].address): trusted])
    try check(trustedFeed.shelves.first?.picks.first?.listing.address == qualityRows[4].address, "Recent reachability boosts a four-star stream above an otherwise similar unchecked five-star stream")
    let audio = DiscoveryProbe.Reply(status: 200, type: "audio/mpeg", location: nil, body: Data(repeating: 1, count: 512))
    let publicURL = URL(string: "https://radio.example/live")!
    try check(DiscoveryProbe.evaluate(publicURL, fetch: { _ in audio }) == .alive, "Availability requires a successful response with stream bytes")
    func site(_ status: Int, _ location: String? = nil) -> DiscoveryProbe.Reply { .init(status: status, type: "text/html", location: location, body: Data()) }
    try check(DiscoveryProbe.siteVerdict(publicURL, fetch: { _ in site(200) }) == .alive && DiscoveryProbe.siteVerdict(publicURL, fetch: { _ in site(403) }) == .unknown, "A homepage that answers, or blocks bots, is not treated as dead")
    try check(DiscoveryProbe.siteVerdict(publicURL, fetch: { _ in site(404) }) == .dead && DiscoveryProbe.siteVerdict(publicURL, fetch: { _ in site(503) }) == .doubtful, "A missing homepage is dead and a server error is doubtful")
    try check(DiscoveryProbe.siteVerdict(publicURL, fetch: { $0.path == "/new" ? site(200) : site(301, "/new") }) == .alive && DiscoveryProbe.siteVerdict(publicURL, fetch: { $0.path == "/new" ? site(410) : site(302, "/new") }) == .dead, "Homepage checks follow redirects to the final answer")
    try check(DiscoveryProbe.evaluate(publicURL, fetch: { _ in .init(status: 200, type: "audio/mpeg", location: nil, body: Data()) }) == .unknown, "Empty audio headers do not verify availability")
    var contacted: [String] = []
    let redirect = DiscoveryProbe.evaluate(publicURL) { url in
        contacted.append(url.absoluteString)
        return .init(status: 302, type: "", location: "http://127.0.0.1/private", body: Data())
    }
    try check(redirect == .unknown && contacted.count == 1, "Private redirect destinations are rejected before transport")
    let hls = DiscoveryProbe.evaluate(URL(string: "https://radio.example/live.m3u8")!) { url in
        url.pathExtension == "m3u8" ? .init(status: 200, type: "application/vnd.apple.mpegurl", location: nil, body: Data("#EXTM3U\n#EXTINF:6,\nsegment.ts\n".utf8)) : .init(status: 200, type: "video/mp2t", location: nil, body: audio.body)
    }
    try check(hls == .alive, "HLS verification follows a playlist to actual segment bytes")
    var loopCalls = 0
    _ = DiscoveryProbe.evaluate(publicURL) { _ in loopCalls += 1; return .init(status: 302, type: "", location: publicURL.absoluteString, body: Data()) }
    try check(loopCalls == 3, "Redirect and playlist cycles have a bounded hop budget")
    for ip in ["127.0.0.1", "10.1.2.3", "169.254.169.254", "172.16.0.1", "192.168.0.1", "100.64.0.1", "198.18.0.1", "224.0.0.1"] {
        try check(!DiscoveryProbe.publicIPv4(ip), "Probe blocks non-public destination: \(ip)")
    }
    try check(DiscoveryProbe.publicIPv4("8.8.8.8") && !DiscoveryProbe.allowed(URL(string: "https://user:secret@radio.example/live")!), "Public IP checks retain credential isolation")
    availability.record(address, verdict: .dead, now: now.addingTimeInterval(4000))
    availability.recordPlayback(address, now: now.addingTimeInterval(4001))
    try check(availability.snapshot(now: now.addingTimeInterval(4001))[key]?.failures == 0, "Playback success clears failure evidence without waiting for the probe retry gap")
    var availabilityPreferences = DiscoveryPreferences(state: Library.State())
    availabilityPreferences.checkAvailability = false
    var availabilityState = Library.State(); availabilityPreferences.apply(to: &availabilityState)
    try check(!DiscoveryPreferences(state: availabilityState).checkAvailability, "Local availability checks can be disabled in saved preferences")
    availability.clear()
    try check(availability.snapshot().isEmpty && !FileManager.default.fileExists(atPath: availabilityFile.path), "Clearing discovery deletes availability evidence")

    func referenceGenres(_ text: String) -> Set<String> {
        let haystack = " " + DiscoveryCatalog.words(text) + " "
        var result = Set(DiscoveryCatalog.genres.filter { haystack.contains(" " + DiscoveryCatalog.words($0) + " ") })
        for (alias, genre) in DiscoveryCatalog.aliases where haystack.contains(" " + DiscoveryCatalog.words(alias) + " ") { result.insert(genre) }
        return result
    }
    let genreSamples = DiscoveryCatalog.genres + Array(DiscoveryCatalog.aliases.keys) + ["rockabilly", "deep-house / drum & bass", "JAZZ café, neo soul", "hip-hop & indie pop", "", "smooth jazz classic rock"]
    try check(genreSamples.allSatisfy { DiscoveryCatalog.matches($0) == referenceGenres($0) }, "Optimized genre lookup preserves vocabulary, aliases, phrase boundaries and accent normalization")

}
