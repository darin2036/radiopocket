import AppKit
import CEQ
import CommonCrypto
import AudioToolbox

var checks = 0
func check(_ condition: @autoclosure () throws -> Bool, _ label: String) throws {
    guard try condition() else { throw RadioError.message("FAIL: \(label)") }
    checks += 1
    print("PASS: \(label)")
}
func rejects(_ label: String, _ operation: () throws -> Void) throws {
    do { try operation() } catch { checks += 1; print("PASS: \(label)"); return }
    throw RadioError.message("FAIL: \(label)")
}

func bitmap(width: Int, height: Int) -> Data {
    let stride = (width * 3 + 3) & ~3
    var data = Data()
    func u16(_ n: Int) { data.append(UInt8(n & 255)); data.append(UInt8((n >> 8) & 255)) }
    func u32(_ n: Int) { u16(n & 65535); u16((n >> 16) & 65535) }
    data.append(contentsOf: [0x42, 0x4d]); u32(54 + stride * height); u32(0); u32(54)
    u32(40); u32(width); u32(height); u16(1); u16(24); u32(0); u32(stride * height)
    u32(0); u32(0); u32(0); u32(0)
    data.append(Data(repeating: 100, count: stride * height))
    return data
}

let root = FileManager.default.temporaryDirectory.appendingPathComponent("RadioPocketChecks-\(UUID())")
do {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try check(DirectoryCacheAge.isIdle(Date().addingTimeInterval(-DirectoryCacheAge.idle - 5)) && !DirectoryCacheAge.isIdle(Date().addingTimeInterval(-5)), "In-memory directory copies count as idle after two minutes")
    try check(StreamAddress.parse(" https://radio.example/live?token=abc \n").host == "radio.example", "HTTP URL normalization")
    for invalid in ["file:///etc/passwd", "ftp://radio.example/live", "radio.example", "https://", "https://example.org/has space"] {
        try rejects("Reject \(invalid)") { _ = try StreamAddress.parse(invalid) }
    }
    let base = URL(string: "https://radio.example/playlists/list.m3u")!
    try check(StreamAddress.playlistEntry("#EXTM3U\n#EXTINF:-1,Radio\n../live.mp3", base: base).absoluteString == "https://radio.example/live.mp3", "Relative M3U entries")
    try check(StreamAddress.playlistEntry("[playlist]\nFile2=https://b.example/live\nFile1=https://a.example/live", base: base).host == "a.example", "Ordered PLS entries")
    try check(StreamAddress.playlistEntry("#EXTM3U\n#EXT-X-TARGETDURATION:6\nsegment.ts", base: base) == base, "HLS manifest is preserved")
    try rejects("Reject local files in playlists") { _ = try StreamAddress.playlistEntry("#EXTM3U\nfile:///tmp/audio.mp3", base: base) }
    let dir = root.appendingPathComponent("library")
    let library = try Library(directory: dir)
    let a = Station(name: "First", address: "https://radio.example/live")
    try library.save(a)
    try library.save(Station(name: "Renamed", address: a.address))
    try check(library.state.favorites.count == 1, "Favorites deduplicate by URL")
    let reopened = try Library(directory: dir)
    try check(reopened.state.favorites.first?.name == "Renamed", "Favorites survive relaunch")
    try reopened.update { $0.favorites.removeAll() }
    try check(Library(directory: dir).state.favorites.isEmpty, "Favorite removal persists")
    let original = Data("not-json".utf8)
    let stateFile = dir.appendingPathComponent("library.json")
    try original.write(to: stateFile)
    try rejects("Report corrupt library") { _ = try Library(directory: dir) }
    try check(Data(contentsOf: stateFile) == original, "Preserve corrupt library without overwriting")
    try rejects("Reject missing skin artwork") { _ = try ClassicSkin(archive: .init(name: "Bad", bitmaps: [:])) }
    try rejects("Reject malformed bitmap") { _ = try ClassicSkin(archive: .init(name: "Bad", bitmaps: ["main.bmp": Data("bad bitmap".utf8)])) }
    let skinDir = root.appendingPathComponent("Nested")
    try FileManager.default.createDirectory(at: skinDir, withIntermediateDirectories: true)
    try bitmap(width: 275, height: 116).write(to: skinDir.appendingPathComponent("MAIN.BMP"))
    try bitmap(width: 136, height: 36).write(to: skinDir.appendingPathComponent("CBUTTONS.BMP"))
    let archive = root.appendingPathComponent("fixture.wsz")
    let zip = Process(); zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
    zip.currentDirectoryURL = root; zip.arguments = ["-q", "-r", archive.path, "Nested"]
    try zip.run(); zip.waitUntilExit()
    try check(zip.terminationStatus == 0, "Create self-contained classic skin fixture")
    var spins = 0
    let probe = Timer(timeInterval: 0.001, repeats: true) { _ in spins += 1 }
    RunLoop.main.add(probe, forMode: .common)
    let skin = try ClassicSkin.load(archive)
    probe.invalidate()
    try check(spins == 0, "Loading a skin never spins the run loop (no painting of a half-launched window; saw \(spins) turns)")
    try check(skin.sprite("main.bmp", NSRect(x: 0, y: 0, width: 275, height: 116)) != nil, "Import nested, case-insensitive .wsz bitmap")
    try check(skin.sprite("cbuttons.bmp", NSRect(x: 23, y: 18, width: 23, height: 18)) != nil, "Import pressed transport sprite")
    try check(skin.sprite("main.bmp", NSRect(x: 10000, y: 0, width: 10, height: 10)) == nil, "Reject out-of-bounds sprite")
    if let path = ProcessInfo.processInfo.environment["RADIOPOCKET_TEST_SKIN"] {
        let real = try ClassicSkin.load(URL(fileURLWithPath: path))
        try check(real.sprite("main.bmp", NSRect(x: 0, y: 0, width: 275, height: 116)) != nil, "Import external classic skin")
        try check(real.glyph("A") != nil, "Read external skin bitmap font")
    }
    try check(EQPreset.classic.count == 18 && Set(EQPreset.classic.map(\.name)).count == 18, "All 18 distinct stock presets")
    try check(EQPreset.classic.allSatisfy { $0.bands.count == 10 && $0.bands.allSatisfy { abs($0) <= 12 } }, "Preset bands are valid")
    for preset in EQPreset.classic {
        let parsed = try EQFile.read(EQFile.write(preset))
        try check(parsed == [preset], "EQF round trip: \(preset.name)")
    }
    try rejects("Reject truncated EQF") { _ = try EQFile.read(Data(EQFile.write(EQPreset.classic[0]).dropLast())) }
    let eqDirectory = root.appendingPathComponent("eq-library")
    let eqLibrary = try Library(directory: eqDirectory)
    try eqLibrary.update { $0.equalizer = EQSettings(enabled: true, preamp: -3, bands: EQPreset.classic[0].bands, preset: "Classical") }
    try check(Library(directory: eqDirectory).state.equalizer?.preamp == -3, "Equalizer settings persist")
    let dsp = rp_eq_create()!
    defer { rp_eq_destroy(dsp) }
    let rate = 48000.0
    let frames = 48000
    func render(frequency: Double, bands: [Float], preamp: Float = 0, enabled: Bool = true) -> (Double, [Float]) {
        rp_eq_prepare(dsp, rate)
        bands.withUnsafeBufferPointer { rp_eq_set(dsp, enabled ? 1 : 0, preamp, $0.baseAddress!) }
        var tone = (0..<frames).map { Float(0.05 * sin(2 * Double.pi * frequency * Double($0) / rate)) }
        tone.withUnsafeMutableBufferPointer { buffer in
            for offset in stride(from: 0, to: frames, by: 256) { rp_eq_process(dsp, buffer.baseAddress!.advanced(by: offset), UInt32(min(256, frames-offset)), 1, 0) }
        }
        let energy = tone.suffix(24000).reduce(0.0) { $0 + Double($1*$1) } / 24000
        return (sqrt(energy) / (0.05 / sqrt(2)), tone)
    }
    let flat = Array(repeating: Float(0), count: 10)
    try check(abs(render(frequency: 1000, bands: flat).0 - 1) < 0.001, "Flat EQ is unity gain")
    try check(abs(render(frequency: 1000, bands: flat, preamp: -12).0 - pow(10,-12.0/20)) < 0.001, "Preamp gives measured -12 dB")
    for (i, hz) in [60,170,310,600,1000,3000,6000,12000,14000,16000].enumerated() {
        var bands = flat; bands[i] = 6
        let ratio = render(frequency: Double(hz), bands: bands).0
        try check(abs(ratio - pow(10,6.0/20)) < 0.025, "Measured +6 dB at \(hz) Hz")
    }
    try check(abs(render(frequency: 1000, bands: Array(repeating: 12, count: 10), preamp: 12, enabled: false).0 - 1) < 0.001, "Bypass ignores every gain")
    let boosted = render(frequency: 1000, bands: Array(repeating: 12, count: 10), preamp: 12).1
    try check(boosted.allSatisfy { $0.isFinite && abs($0) <= 1 }, "Output stays finite and bounded")
    rp_eq_prepare(dsp, rate)
    let stereoBands: [Float] = [0,0,0,0,6,0,0,0,0,0]
    stereoBands.withUnsafeBufferPointer { rp_eq_set(dsp, 1, -3, $0.baseAddress!) }
    var left = (0..<1024).map { Float(0.05 * sin(2 * Double.pi * 1000 * Double($0) / rate)) }
    var right = left
    left.withUnsafeMutableBufferPointer { rp_eq_process(dsp, $0.baseAddress!, 1024, 1, 0) }
    right.withUnsafeMutableBufferPointer { rp_eq_process(dsp, $0.baseAddress!, 1024, 1, 1) }
    try check(left == right, "Planar stereo channels keep identical gain while smoothing")
    rp_eq_prepare(dsp, 22050)
    var lowRate = (0..<1024).map { Float(0.05 * sin(Double($0))) }
    Array(repeating: Float(12), count: 10).withUnsafeBufferPointer { rp_eq_set(dsp, 1, 0, $0.baseAddress!) }
    lowRate.withUnsafeMutableBufferPointer { rp_eq_process(dsp, $0.baseAddress!, 1024, 1, 0) }
    try check(lowRate.allSatisfy { $0.isFinite && abs($0) <= 1 }, "Low sample-rate streams safely bypass bands above Nyquist")
    var query = DirectoryQuery()
    query.name = "Miles & Jazz + Live"; query.genre = "jazz"; query.countryCode = "US"; query.minimumBitrate = 128; query.offset = 100
    var components = URLComponents(string: "https://example.org/json/stations/search")!
    components.queryItems = query.items
    try check(URLComponents(url: components.url!, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "name" })?.value == query.name, "Directory search safely encodes special characters")
    try check(query.items.contains(.init(name: "hidebroken", value: "true")) && query.items.contains(.init(name: "limit", value: "100")), "Directory requests are paged and hide broken stations")
    try check(query.items.contains(.init(name: "tagExact", value: "true")) && query.items.contains(.init(name: "bitrateMin", value: "128")), "Genre and bitrate filters reach the API")
    let firstID = "00000000-0000-0000-0000-000000000001"
    let secondID = "00000000-0000-0000-0000-000000000002"
    let rawRows: [[String: Any]] = [
        ["stationuuid": firstID, "name": "Test\nRadio", "url": "https://radio.example/original", "url_resolved": "https://radio.example/resolved", "codec": "MP3", "bitrate": "128", "votes": 12, "countrycode": "US"],
        ["stationuuid": secondID, "name": "Flac Radio", "url": "https://radio.example/flac", "codec": "FLAC"],
        ["stationuuid": firstID, "name": "Duplicate", "url": "https://radio.example/duplicate", "codec": "MP3"],
        ["stationuuid": "bad-id", "url": "https://radio.example/live", "codec": "MP3"],
        ["stationuuid": "00000000-0000-0000-0000-000000000003", "url": "file:///tmp/music.mp3", "codec": "MP3"]
    ]
    let rawData = try JSONSerialization.data(withJSONObject: rawRows)
    let decoded = try RadioDirectory.decodePage(rawData, query: query)
    try check(decoded.stations.count == 1 && decoded.rawCount == 5, "Directory hides unsupported, malformed, duplicate, and non-HTTP entries")
    let opusRows = try JSONSerialization.data(withJSONObject: [["stationuuid": secondID, "name": "Opus Radio", "url": "https://radio.example/opus", "codec": "OPUS"]])
    try check(try RadioDirectory.decodePage(opusRows, query: query).stations.count == 1, "Opus stations are listed as playable")
    try check(decoded.stations[0].name == "Test Radio" && decoded.stations[0].bitrate == 128, "Directory sanitizes labels and tolerates numeric strings")
    try check(decoded.stations[0].address == "https://radio.example/resolved", "Discovered playback uses the resolved stream URL")
    try check(decoded.stations[0].station.id.uuidString.lowercased() == firstID, "Discovered favorites retain their station identity")
    query.supportedOnly = false
    try check(RadioDirectory.decodePage(rawData, query: query).stations.count == 2, "All formats exposes other codec listings")
    let hls = try JSONSerialization.data(withJSONObject: [["stationuuid": secondID, "name": "HLS", "url": "https://radio.example/live.m3u8", "url_resolved": "javascript:bad()", "hls": 1]])
    query.supportedOnly = true
    try check(RadioDirectory.decodePage(hls, query: query).stations.first?.address == "https://radio.example/live.m3u8", "Valid source URL survives invalid resolved URL and HLS remains discoverable")
    let fullPage = try JSONSerialization.data(withJSONObject: Array(repeating: rawRows[0], count: 100))
    try check(RadioDirectory.decodePage(fullPage, query: query).hasMore, "Pagination uses server row count before local filtering")
    try rejects("Reject malformed directory JSON") { _ = try RadioDirectory.decodePage(Data("not JSON".utf8), query: query) }
    let excessiveRows = try JSONSerialization.data(withJSONObject: Array(repeating: rawRows[0], count: 201))
    try rejects("Reject unbounded directory pages before allocating station models") { _ = try RadioDirectory.decodePage(excessiveRows, query: query) }
    // Saved station lists
    let cacheDir = root.appendingPathComponent("station-cache")
    let saved = StationCache(directory: cacheDir)
    var savedRow = RadioListing(id: "00000000-0000-0000-0000-0000000000aa", name: "Saved Jazz", address: "https://radio.example/jazz", tags: "jazz", country: "France", countryCode: "FR", codec: "AAC", bitrate: 96, votes: 7, clicks: 9, hls: false, sourceName: "SomaFM")
    savedRow.directoryID = "00000000-0000-0000-0000-0000000000aa"; savedRow.homepage = "https://radio.example/"
    let browse = DirectoryQuery()
    let savedKey = saved.key(for: browse, sources: ["radio-browser@", "somafm@"])!
    saved.store(DirectoryPage(stations: [savedRow], hasMore: true, rawCount: 100), key: savedKey)
    let reloaded = saved.load(savedKey)
    try check(reloaded?.page.stations == [savedRow] && reloaded?.page.hasMore == true && reloaded?.page.rawCount == 100 && reloaded?.page.cached == true, "A saved station page reloads with every field intact")
    var typed = DirectoryQuery(); typed.name = "jazz"
    try check(saved.key(for: typed, sources: ["radio-browser@"]) == nil, "Typed searches are never saved")
    var secondPage = browse; secondPage.offset = 100; var otherSort = browse; otherSort.order = "votes"
    let keys = Set([browse, secondPage, otherSort].compactMap { saved.key(for: $0, sources: ["radio-browser@"]) } + [saved.key(for: browse, sources: ["radio-browser@", "somafm@"])!])
    try check(keys.count == 4 && saved.key(for: browse, sources: ["somafm@", "radio-browser@"]) == savedKey, "Saved pages are keyed by view, offset and enabled directories, not by source order")
    let oldDate = Date().addingTimeInterval(-7200)
    try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: cacheDir.appendingPathComponent(savedKey + ".json").path)
    try check(abs((saved.age(of: savedKey) ?? 0) - 7200) < 5 && saved.load(savedKey)?.page.updated == saved.load(savedKey)?.savedAt, "A saved page's age is its file's modification time")
    let tampered = String(decoding: try Data(contentsOf: cacheDir.appendingPathComponent(savedKey + ".json")), as: UTF8.self).replacingOccurrences(of: "https://radio.example/jazz", with: "file:///etc/passwd")
    try tampered.write(to: cacheDir.appendingPathComponent(savedKey + ".json"), atomically: true, encoding: .utf8)
    try check(saved.load(savedKey)?.page.stations.isEmpty == true, "Saved addresses are revalidated when read back")
    try Data("not json".utf8).write(to: cacheDir.appendingPathComponent(savedKey + ".json"))
    try check(saved.load(savedKey) == nil, "A damaged saved page is ignored")
    for index in 0..<(StationCache.maximumFiles + 20) {
        var q = browse; q.offset = index * 100
        saved.store(DirectoryPage(stations: [savedRow], hasMore: false, rawCount: 1), key: saved.key(for: q, sources: ["prune@"])!)
    }
    let ancient = saved.key(for: browse, sources: ["prune@"])!
    try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-StationCache.maximumAge - 60)], ofItemAtPath: cacheDir.appendingPathComponent(ancient + ".json").path)
    saved.prune()
    let kept = try FileManager.default.contentsOfDirectory(atPath: cacheDir.path).filter { $0.hasSuffix(".json") }.count
    try check(kept <= StationCache.maximumFiles && saved.load(ancient) == nil, "Pruning drops month-old pages and caps the number of saved pages")
    saved.clear()
    try check(!FileManager.default.fileExists(atPath: cacheDir.path), "Clearing removes the saved pages")
    let historyDir = root.appendingPathComponent("history")
    let history = try Library(directory: historyDir)
    for i in 0..<35 { try history.recordRecent(Station(name: "Station \(i)", address: "https://radio.example/\(i)")) }
    try check(history.state.recentStations?.count == 30, "Recently Played is bounded to 30 stations")
    try history.recordRecent(history.state.recentStations!.last!)
    try check(history.state.recentStations?.count == 30 && history.state.recentStations?.first?.name == "Station 5", "Replaying moves a station to the front without duplicates")
    try check(Library(directory: historyDir).state.recentStations?.count == 30, "Recently Played survives relaunch")
    if let path = ProcessInfo.processInfo.environment["RADIOPOCKET_DIRECTORY_FIXTURE"] {
        try check(!RadioDirectory.decodePage(Data(contentsOf: URL(fileURLWithPath: path)), query: DirectoryQuery()).stations.isEmpty, "Decode live Radio Browser response")
    }
    // Multiple directories
    let m3u = "#EXTM3U\n#EXTINF:-1 group-title=\"Jazz\",Late Night Jazz\nhttps://jazz.example/live.mp3\n#EXTINF:-1,Dupe\nhttps://jazz.example/live.mp3\nftp://bad.example/x\n#EXTINF:-1,Relative\n/streams/two\n"
    let listed = StationListDirectory.parse(m3u, base: URL(string: "https://lists.example/radio.m3u")!, label: "Mine", sourceID: "custom-1")
    try check(listed.count == 2 && listed[0].name == "Late Night Jazz" && listed[0].tags == "Jazz" && listed[0].codec == "MP3", "M3U station lists keep names and groups, and skip duplicates and non-HTTP entries")
    try check(listed[1].address == "https://lists.example/streams/two" && listed[1].likelyPlayable, "Relative M3U entries resolve against the list URL and unknown codecs stay playable")
    let junk = "#EXTM3U\nhttps://ice4.somafm.com/groovesalad-128-mp3\n#EXTINF:-1,ice4.somafm.com\nhttps://ice4.somafm.com/x\n#EXTINF:-1,https://a.example/s\nhttps://a.example/s\n#EXTINF:-1,---\nhttps://b.example/s\n#EXTINF:-1,Cover\nhttps://c.example/art.jpg\n#EXTINF:-1,Real Station\nhttps://d.example/live\n"
    try check(StationListDirectory.parse(junk, base: URL(string: "https://lists.example/j.m3u")!, label: "J", sourceID: "j").map(\.name) == ["Real Station"], "Untitled, host-named, symbol-only and non-audio entries are not imported")
    let pls = "[playlist]\nFile1=https://a.example/one\nTitle1=One\nFile2=https://a.example/two\nTitle2=Two\n"
    func listing(_ name: String, _ codec: String, _ bitrate: Int, votes: Int = 0) -> RadioListing {
        RadioListing(id: name, name: name, address: "http://x/\(name)", tags: "", country: "", countryCode: "", codec: codec, bitrate: bitrate, votes: votes, clicks: 0, hls: false, sourceName: nil)
    }
    try check(listing("a", "MP3", 128).quality == 3 && listing("b", "AAC+", 64).quality == 3 && listing("c", "OPUS", 32).quality == 2 && listing("d", "MP3", 0).quality == 0 && listing("e", "FLAC", 0).quality == 5 && listing("f", "MP3", 320).quality == 5, "Quality stars normalise codec and bitrate")
    let sortRows = [listing("lo", "MP3", 64, votes: 5), listing("hi", "MP3", 320, votes: 1), listing("opus", "OPUS", 96, votes: 9), listing("none", "MP3", 0, votes: 3)]
    try check(RadioListing.ordered(sortRows, by: "bitrate", reverse: true).map(\.name) == ["hi", "opus", "lo", "none"], "Bitrate sort is numeric and descending")
    try check(RadioListing.ordered(sortRows, by: "votes", reverse: false).map(\.name) == ["hi", "none", "lo", "opus"], "Votes sort is numeric and ascending")
    try check(RadioListing.ordered(sortRows, by: "quality", reverse: true).map(\.name) == ["hi", "opus", "lo", "none"], "Quality sort ranks best first")
    try check(StationListDirectory.parse(pls, base: URL(string: "https://lists.example/r.pls")!, label: "Mine", sourceID: "c").map(\.name) == ["One", "Two"], "PLS station lists are parsed in order")
    try check(listed[0].id == StationListDirectory.parse(m3u, base: URL(string: "https://lists.example/radio.m3u")!, label: "Mine", sourceID: "custom-1")[0].id, "Station identifiers are stable between loads")
    var filtered = DirectoryQuery(); filtered.name = "jazz"
    try check(DirectoryFilter.page(listed, query: filtered).stations.count == 1, "Local directories filter by name or genre")
    var paged = DirectoryQuery(); paged.offset = 1
    try check(DirectoryFilter.page(listed, query: paged).stations.count == 1 && !DirectoryFilter.page(listed, query: paged).hasMore, "Local directories page like the network ones")
    let resolvedSources = DirectorySource.resolved([DirectorySource(id: "somafm", name: "x", kind: .somaFM, enabled: false), try DirectorySource.custom(name: "Mine", url: "https://lists.example/radio.m3u", kind: .stationList)])
    try check(resolvedSources.map(\.id).prefix(2) == ["radio-browser", "somafm"] && !resolvedSources[1].enabled && resolvedSources.count == 9, "Built-in directories always exist; saved choices and custom directories are kept")
    try check(DirectorySource.defaults.count == 8 && DirectorySource.defaults.filter(\.enabled).count == 5, "Eight built-in catalogs; larger feeds are opt-in")
    try check(DirectorySource.defaults.allSatisfy(\.builtIn) && DirectorySource.resolved(resolvedSources).count == 9, "Built-in migration is idempotent and does not duplicate saved sources")
    let oldChoices = [DirectorySource.radioBrowser, DirectorySource.somaFM, DirectorySource.lautFM, DirectorySource.icecast, DirectorySource.iprd]
    let upgradedChoices = DirectorySource.resolved(oldChoices)
    try check(upgradedChoices.count == 8 && upgradedChoices.contains { $0.id == "curated-streams" && $0.enabled } && upgradedChoices.contains { $0.id == "junguler" && !$0.enabled }, "Existing five-source settings gain the new sources with lightweight defaults")
    let collectionDirectory = root.appendingPathComponent("Collection")
    try FileManager.default.createDirectory(at: collectionDirectory.appendingPathComponent("DEMOTED"), withIntermediateDirectories: true)
    try Data("#EXTM3U\n#EXTINF:-1,Keep Radio\n#EXTGENRE: electronic\nhttps://keep.example/live\n".utf8).write(to: collectionDirectory.appendingPathComponent("Keep.m3u"))
    try Data("#EXTM3U\n#EXTINF:-1,Old Radio\nhttps://old.example/live\n".utf8).write(to: collectionDirectory.appendingPathComponent("DEMOTED/Old.m3u"))
    let collectionZIP = root.appendingPathComponent("collection.zip")
    let collectionProcess = Process(); collectionProcess.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
    collectionProcess.currentDirectoryURL = root; collectionProcess.arguments = ["-q", "-r", collectionZIP.path, "Collection"]
    try collectionProcess.run(); collectionProcess.waitUntilExit()
    let collectionText = try CuratedStreamsDirectory.playlist(Data(contentsOf: collectionZIP))
    let collectionRows = StationListDirectory.parse(collectionText, base: URL(string: "https://collection.example/")!, label: "Curated", sourceID: "curated")
    try check(collectionRows.count == 1 && collectionRows.first?.name == "Keep Radio" && collectionRows.first?.tags == "electronic", "Curated archive retains station names and EXTGENRE, excluding DEMOTED playlists")
    try rejects("Curated archive rejects invalid ZIP data") { _ = try CuratedStreamsDirectory.playlist(Data("bad zip".utf8)) }
    try rejects("Curated archive enforces its download cap") { _ = try CuratedStreamsDirectory.playlist(Data(repeating: 0, count: 1_048_577)) }
    let groupedText = "#EXTM3U\n#PLAYLIST: smooth_jazz.m3u\n#EXTINF:-1,First\nhttps://one.example/live\n#EXTINF:-1 group-title=\"Fusion\",Second\nhttps://two.example/live\n#PLAYLIST: ambient.m3u\n#EXTINF:-1,Third\nhttps://three.example/live\n"
    let grouped = StationListDirectory.parse(groupedText, base: URL(string: "https://collection.example/")!, label: "Junguler", sourceID: "junguler")
    try check(grouped.map(\.tags) == ["smooth jazz", "Fusion", "ambient"], "Junguler playlist sections become searchable genres while explicit tags take precedence")
    let paradise = try await RadioParadiseDirectory().search(DirectoryQuery(), refresh: false)
    try check(paradise.stations.count == 4 && paradise.stations.allSatisfy { $0.codec == "AAC" && $0.bitrate == 128 && $0.sourceName == "Radio Paradise" }, "Radio Paradise exposes four direct AAC mixes without a catalog download")
    var rockQuery = DirectoryQuery(); rockQuery.genre = "rock"
    let rockParadise = try await RadioParadiseDirectory().search(rockQuery, refresh: false)
    try check(rockParadise.stations.contains { $0.name.contains("Rock Mix") }, "Radio Paradise mixes participate in genre filtering")
    let quotedList = "#EXTM3U\n#EXTINF:-1 group-title=\"Jazz,Blues\" tvg-logo=\"https://img.example/a,b.png\",Station, One\nhttps://radio.example/live\n"
    let quotedRows = StationListDirectory.parse(quotedList, base: URL(string: "https://lists.example/r.m3u")!, label: "IPRD", sourceID: "iprd")
    try check(quotedRows.first?.name == "Station, One" && quotedRows.first?.tags == "Jazz,Blues", "IPRD-style M3U commas in quoted attributes preserve station names")
    let xml = "<directory><entry><server_name>Jazz &amp; Soul</server_name><server_type>audio/mpeg</server_type><bitrate>128</bitrate><genre>Jazz</genre><listen_url>https://radio.example/live</listen_url></entry><entry><listen_url>file:///etc/passwd</listen_url></entry><entry><listen_url></listen_url></entry></directory>"
    let ice = try IcecastDirectory.parse(Data(xml.utf8))
    try check(ice.count == 1 && ice[0].name == "Jazz & Soul" && ice[0].codec == "MP3" && ice[0].bitrate == 128, "Icecast decodes XML entities, formats and bitrate while skipping invalid streams")
    try rejects("Icecast rejects malformed XML") { _ = try IcecastDirectory.parse(Data("<directory><entry>".utf8)) }
    try rejects("Icecast rejects entity declarations") { _ = try IcecastDirectory.parse(Data("<!DOCTYPE directory [<!ENTITY x SYSTEM 'file:///etc/passwd'>]><directory/>".utf8)) }
    let lautBrowse = Data(#"{"items":[{"name":"jazz","display_name":"Jazz","stream_url":"https://jazz.example/live","genres":["Jazz"],"active":true},{"name":"bad","stream_url":"file:///tmp/audio"},{"name":"off","stream_url":"https://off.example/live","active":false}],"next_offset":100}"#.utf8)
    let lautPage = try LautFMDirectory.decode(lautBrowse, query: DirectoryQuery())
    try check(lautPage.stations.count == 1 && lautPage.hasMore && lautPage.rawCount == 3 && lautPage.stations[0].sourceName == "laut.fm", "laut.fm browse pages skip invalid and inactive stations while retaining server pagination")
    var lautQuery = DirectoryQuery(); lautQuery.name = "Jazz & Soul"; lautQuery.offset = 100
    let lautURL = URLComponents(url: LautFMDirectory.requestURL(lautQuery), resolvingAgainstBaseURL: false)!
    try check(lautURL.host == "search.api.laut.fm" && lautURL.queryItems?.first(where: { $0.name == "query" })?.value == "Jazz & Soul" && lautURL.queryItems?.first(where: { $0.name == "offset" })?.value == "100", "laut.fm search safely encodes names and page offsets")
    let lautSearch = Data(#"{"results":[{"station":{"name":"jazz","stream_url":"https://jazz.example/live","genres":["Jazz"]}}],"next_offset":null}"#.utf8)
    var jazzQuery = DirectoryQuery(); jazzQuery.genre = "Jazz"
    try check(try LautFMDirectory.decode(lautSearch, query: jazzQuery).stations.count == 1 && !LautFMDirectory.decode(lautSearch, query: jazzQuery).hasMore, "laut.fm search envelope and final-page detection")
    try rejects("Custom directories need an http(s) address") { _ = try DirectorySource.custom(name: "x", url: "ftp://lists.example/a.m3u", kind: .stationList) }
    if ProcessInfo.processInfo.environment["RADIOPOCKET_LIVE_DIRECTORIES"] != nil {
        let curatedClient = CuratedStreamsDirectory()
        let curatedPage = try await curatedClient.search(DirectoryQuery(), refresh: true)
        try check(curatedPage.stations.count > 30 && curatedPage.stations.allSatisfy { $0.sourceName == "Curated Internet Radio Streams" }, "Live curated collection loads named stations in a single archive request")
        let cachedCurated = try await curatedClient.search(DirectoryQuery(), refresh: false)
        try check(cachedCurated.cached && cachedCurated.stations.map(\.id) == curatedPage.stations.map(\.id), "Curated catalog cache retains stable station IDs")
        let jungulerClient = DirectorySource.junguler.makeBackend()!
        var lastPage = DirectoryQuery(); lastPage.offset = 6000
        let jungulerPage = try await jungulerClient.search(lastPage, refresh: true)
        try check(!jungulerPage.stations.isEmpty && jungulerPage.stations.allSatisfy { !$0.name.isEmpty }, "Live named Junguler catalog includes stations beyond the custom-list cap")
        let laut = try await LautFMDirectory().search(DirectoryQuery(), refresh: true)
        try check(!laut.stations.isEmpty && laut.hasMore, "Live laut.fm browse loads a bounded page")
        var liveJazz = DirectoryQuery(); liveJazz.name = "jazz"
        let lautSearch = try await LautFMDirectory().search(liveJazz, refresh: true)
        try check(!lautSearch.stations.isEmpty, "Live laut.fm keyword search loads")
        let ice = try await IcecastDirectory().search(DirectoryQuery(), refresh: true)
        try check(!ice.stations.isEmpty, "Live Icecast catalog loads")
        let iprd = try await DirectorySource.iprd.makeBackend()!.search(DirectoryQuery(), refresh: true)
        try check(!iprd.stations.isEmpty && iprd.hasMore, "Live IPRD catalog loads beyond the first page")
        let soma = try await SomaFMDirectory().search(DirectoryQuery(), refresh: true)
        try check(!soma.stations.isEmpty && soma.stations.allSatisfy { $0.sourceName == "SomaFM" }, "Live SomaFM channels load")
    }
    let bundled = URL(fileURLWithPath: "Resources/Skins", isDirectory: true)
    let skinFiles = try FileManager.default.contentsOfDirectory(at: bundled, includingPropertiesForKeys: nil).filter { $0.pathExtension == "wsz" }
    try check(skinFiles.count == 11, "Eleven distinct classic skins are bundled")
    for url in skinFiles {
        let skin = try ClassicSkin.load(url)
        try check(skin.sprite("main.bmp", NSRect(x: 0, y: 0, width: 275, height: 116)) != nil && skin.sprite("eqmain.bmp", NSRect(x: 0, y: 0, width: 275, height: 116)) != nil, "Bundled player and equalizer artwork: \(url.lastPathComponent)")
    }
    let shared = Station(name: "Jazz & café", address: "https://radio.example/live?token=a%26b&x=1#part")
    let linked = try ExternalRadioLink.station(for: ExternalRadioLink.link(for: shared))
    try check(linked.name == shared.name && linked.address == shared.address, "External links round-trip nested query, fragment and Unicode")
    for bad in ["radiopocket://play?url=file%3A%2F%2F%2Fetc%2Fpasswd", "radiopocket://other?url=https://radio.example/live", "radiopocket://play?url=https://a.example&url=https://b.example", "radiopocket://play", "javascript:alert(1)"] {
        try rejects("Reject malformed or unsafe external link") { _ = try ExternalRadioLink.station(for: URL(string: bad)!) }
    }
    for ext in ["m3u", "m3u8", "pls"] {
        let file = root.appendingPathComponent("download.\(ext)")
        let text = ext == "pls" ? "[playlist]\nFile1=https://radio.example/live\n" : "\u{FEFF}#EXTM3U\nhttps://radio.example/live\n"
        try text.write(to: file, atomically: true, encoding: .utf8)
        try check(ExternalRadioLink.station(for: file).address == "https://radio.example/live", "Open downloaded \(ext) playlist")
    }
    let badFile = root.appendingPathComponent("bad.m3u")
    for text in ["file:///etc/passwd", "relative.mp3", "#EXTM3U\n#EXT-X-TARGETDURATION:10\nhttps://radio.example/segment.aac", String(repeating: "x", count: 262_145)] {
        try text.write(to: badFile, atomically: true, encoding: .utf8)
        try rejects("Reject local media, downloaded HLS or oversized playlist") { _ = try ExternalRadioLink.station(for: badFile) }
    }
    let field = NSTextField(); ClassicUI.field(field)
    try check(field.font?.pointSize == ClassicUI.font.pointSize && field.bezelStyle == .squareBezel && field.textColor == ClassicUI.text, "Shared dialog and library field typography and square styling")
    try check(ClassicUI.small == ClassicUI.font, "Equivalent compact control labels share font metrics")
    let baseSkin = try ClassicSkin.load(bundled.appendingPathComponent("base-2.91.wsz"))
    try check(baseSkin.sprite("gen.bmp", NSRect(x: 130, y: 0, width: 25, height: 20)) != nil, "Original skin provides panel chrome")
    for gain in [-12.0, 0, 12] {
        let frame = Int(((gain + 12) / 24 * 27).rounded())
        try check(baseSkin.sprite("eqmain.bmp", NSRect(x: 13 + (frame % 14) * 15, y: 164 + (frame / 14) * 65, width: 14, height: 63)) != nil, "EQ endpoint and center slider backgrounds stay in sprite bounds")
    }
    let aqua = try ClassicSkin.load(bundled.appendingPathComponent("MacOSXAqua1-5.wsz"))
    let aquaBG = aqua.displayBackground.usingColorSpace(.deviceRGB)!
    let aquaFG = aqua.displayForeground.usingColorSpace(.deviceRGB)!
    try check(aquaBG.redComponent > 0.8 && aquaFG.redComponent < 0.3, "Aqua display preserves light background and dark text")
    try check(baseSkin.displayBackground.usingColorSpace(.deviceRGB)!.greenComponent < 0.2 && baseSkin.displayForeground.usingColorSpace(.deviceRGB)!.greenComponent > 0.7, "Original skin display preserves dark background and green text")
    let sample = Changelog.parse("RadioPocket 1.1\nReleased: Jan 2 2027\n* Added: Thing\n* Fixed: Other\n\nRadioPocket 1.0\n* Misc: First\n")
    try check(sample.map(\.version) == ["1.1", "1.0"], "Changelog parses release headers")
    try check(sample[0].released == "Jan 2 2027" && sample[1].released == nil, "Changelog release date is optional")
    try check(sample[0].entries == ["* Added: Thing", "* Fixed: Other"], "Changelog keeps entries in order")
    let shipped = Changelog.parse(try String(contentsOfFile: "Resources/CHANGELOG.txt", encoding: .utf8))
    try check(!shipped.isEmpty && shipped.allSatisfy { !$0.entries.isEmpty }, "Shipped CHANGELOG.txt parses with entries for every release")
    let kinds = ["Changed", "Added", "Improved", "Fixed", "Removed", "Updated", "Misc"]
    try check(shipped.flatMap(\.entries).allSatisfy { line in kinds.contains { line.hasPrefix("* \($0): ") } }, "Every changelog entry uses a standard kind prefix")
    // Visualizer: capture ring, analyzer, palette and settings
    let visDSP = rp_eq_create()!
    defer { rp_eq_destroy(visDSP) }
    rp_eq_prepare(visDSP, 44100)
    rp_eq_volume(visDSP, 0.1)
    var stereo = [Float](repeating: 0, count: 2 * 4096)
    for n in 0..<4096 { stereo[2 * n] = 0.4 * sinf(2 * .pi * 1000 * Float(n) / 44100); stereo[2 * n + 1] = 0.2 * sinf(2 * .pi * 1000 * Float(n) / 44100) }
    let expected = stereo
    rp_eq_process(visDSP, &stereo, 4096, 2, 0)
    var captured = [Float](repeating: 0, count: 1024)
    _ = rp_vis_read(visDSP, &captured, 1024)
    var worst: Float = 0
    for i in 0..<1024 { worst = max(worst, abs(captured[i] - (expected[2 * (3072 + i)] + expected[2 * (3072 + i) + 1]) / 2)) }
    try check(worst < 1e-5, "Visualizer capture is the newest stereo-mixed audio, independent of volume (\(worst))")
    try check(abs(stereo[2 * 100] - expected[2 * 100] * 0.1) < 1e-5, "Playback volume still applies after capture")
    let panDSP = rp_eq_create()!
    defer { rp_eq_destroy(panDSP) }
    rp_eq_prepare(panDSP, 44100); rp_eq_channels(panDSP, 2)
    func panned(_ balance: Float) -> (Float, Float) {
        rp_eq_balance(panDSP, balance)
        var frame: [Float] = [1, 1, 1, 1]
        rp_eq_process(panDSP, &frame, 2, 2, 0)
        return (frame[2], frame[3])
    }
    try check(panned(0) == (1, 1), "Centered balance leaves both channels untouched")
    try check(panned(0.5) == (0.5, 1) && panned(-0.25) == (1, 0.75) && panned(1) == (0, 1) && panned(-1) == (1, 0), "Balance turns down only the opposite channel")
    rp_eq_channels(panDSP, 1); rp_eq_balance(panDSP, 1)
    var lone: [Float] = [1, 1]
    rp_eq_process(panDSP, &lone, 2, 1, 0)
    try check(lone == [1, 1], "A mono stream is left to the output's pan, not silenced by the balance")
    try check(StereoBalance.snapped(0.15) == 0 && StereoBalance.snapped(-0.19) == 0 && StereoBalance.snapped(0.25) == 0.25 && StereoBalance.snapped(-3) == -1 && StereoBalance.snapped(2) == 1, "Dragging near the middle snaps to center balance and the ends clamp")
    var short = [Float](repeating: 1, count: 8)
    let fresh = rp_eq_create()!
    defer { rp_eq_destroy(fresh) }
    try check(rp_vis_read(fresh, &short, 8) == 0 && short.allSatisfy { $0 == 0 }, "Empty capture ring reads as silence")

    let analyzer = SpectrumAnalyzer()
    func tone(_ hz: Float, _ amplitude: Float) -> [Float] { (0..<2048).map { amplitude * sinf(2 * .pi * hz * Float($0) / 44100) } }
    func loudestBand(_ values: [Float]) -> Int { values.indices.max { values[$0] < values[$1] }! }
    let low = analyzer.bands(from: tone(200, 0.05), sampleRate: 44100)
    let mid = analyzer.bands(from: tone(1000, 0.01), sampleRate: 44100)
    let high = analyzer.bands(from: tone(8000, 0.05), sampleRate: 44100)
    try check(loudestBand(low) < loudestBand(mid) && loudestBand(mid) < loudestBand(high), "Analyzer places 200 Hz, 1 kHz and 8 kHz in rising bands")
    let ratio = powf(16000 / 45, 1 / Float(SpectrumAnalyzer.bands))
    let centerHz = 45 * powf(ratio, Float(loudestBand(mid)) + 0.5)
    try check(abs(centerHz - 1000) / 1000 < 0.12, "1 kHz tone lands in the band centred near 1 kHz (\(centerHz) Hz)")
    try check(abs(mid[loudestBand(mid)] - 0.73) < 0.12, "Analyzer amplitude calibration: 0.01 tone reads ≈ -37 dB (\(mid[loudestBand(mid)]))")
    try check(analyzer.bands(from: [Float](repeating: 0, count: 2048), sampleRate: 44100).allSatisfy { $0 == 0 }, "Silence produces empty bars")
    let falling = SpectrumAnalyzer()
    falling.advance(raw: mid, scope: [Float](repeating: 0, count: 576), dt: 0.033, falloff: 2)
    let peakBar = falling.frame.bars[loudestBand(mid)]
    falling.advance(raw: [Float](repeating: 0, count: SpectrumAnalyzer.bands), scope: [Float](repeating: 0, count: 576), dt: 0.1, falloff: 2)
    try check(falling.frame.bars[loudestBand(mid)] < peakBar && falling.frame.bars[loudestBand(mid)] > 0, "Bars fall gradually")
    try check(falling.frame.peaks[loudestBand(mid)] >= peakBar - 0.001, "Peak marker holds after the bar falls")
    for _ in 0..<200 { falling.decay(dt: 0.05, falloff: 2) }
    try check(falling.isSilent, "Analyzer decays to silence so the display timer can stop")
    let wave = tone(441, 0.3)
    let scope = SpectrumAnalyzer.scopeWindow(from: wave)
    try check(scope.count == 576 && scope[0] <= 0.05 && scope[1] > scope[0], "Oscilloscope triggers on a rising zero crossing")

    let stock = VisColors.parse("0,0,0 // background\n24,33,41 // dots\n239,49,16 // peak\n")
    try check(stock.count == 24 && stock[2].r == 239 && stock[2].g == 49 && stock[3].r == VisColors.standard[3].r, "VISCOLOR.TXT parses with comments and falls back for missing entries")
    let clamped = VisColors.parse("garbage\n\n300,-5,7")[0]
    try check(clamped.r == 255 && clamped.g == 0 && clamped.b == 7, "VISCOLOR.TXT values are clamped")
    let savedVis = try JSONDecoder().decode(VisSettings.self, from: Data(#"{"mini":"nonsense","falloff":99,"coloring":"fire"}"#.utf8))
    try check(savedVis.mini == MiniVisMode.spectrum && savedVis.falloff == 4 && savedVis.coloring == VisColoring.fire && savedVis.refresh == VisRefresh.half, "Saved visualizer settings tolerate unknown or missing values")
    let roundTrip = try JSONDecoder().decode(VisSettings.self, from: JSONEncoder().encode(VisSettings()))
    try check(roundTrip == VisSettings(), "Visualizer settings round trip")
    // Time-shift ring
    let ring = PacketRing(maxSeconds: 5)
    ring.configure(sampleRate: 8000)
    for _ in 0..<4 { ring.append(AudioPacket(data: Data(count: 10), frames: 8000)) }
    var epoch = ring.currentEpoch
    try check(abs(ring.secondsBehindLive - 4) < 0.001, "Ring reports seconds between cursor and live edge")
    _ = ring.next(epoch: &epoch); _ = ring.next(epoch: &epoch)
    try check(abs(ring.secondsBehindLive - 2) < 0.001, "Consuming packets moves the cursor toward live")
    try check(abs(ring.seek(by: -1.5) - 3.5) < 0.6, "Seeking back moves the cursor into history")
    var seenEpoch = epoch
    _ = ring.next(epoch: &seenEpoch)
    try check(seenEpoch != epoch, "A seek changes the epoch so the pump can flush")
    ring.goLive()
    try check(ring.secondsBehindLive == 0, "Go live puts the cursor at the live edge")
    for _ in 0..<20 { ring.append(AudioPacket(data: Data(count: 10), frames: 8000)) }
    try check(ring.retainedSeconds <= 6.01 && ring.retainedSeconds >= 4.99, "Ring trims history beyond its time budget (\(ring.retainedSeconds) s)")
    ring.seek(by: -100)
    try check(ring.secondsBehindLive <= 6.01, "Rewind clamps to the retained window")
    ring.close()
    var closedEpoch = 0
    try check(ring.next(epoch: &closedEpoch) == nil, "A closed ring wakes readers with nil")

    // Opus and Ogg
    try check(OpusInfo.frames(in: Data([0xFC])) == 960 && OpusInfo.frames(in: Data([0xFD, 0])) == 1920 && OpusInfo.frames(in: Data([0xFB, 0x03])) == 2880 && OpusInfo.frames(in: Data([0x08])) == 960 && OpusInfo.frames(in: Data()) == 0, "Opus packet durations come from the TOC byte")
    final class Recorder: PacketSink {
        var formats: [AudioStreamBasicDescription] = [], packets: [AudioPacket] = [], titles: [String] = [], failures: [String] = []
        func sinkFormat(_ format: AudioStreamBasicDescription, cookie: Data?) { formats.append(format) }
        func sinkPacket(_ packet: AudioPacket) { packets.append(packet) }
        func sinkTitle(_ text: String) { titles.append(text) }
        func sinkFailure(_ message: String) { failures.append(message) }
    }
    func oggPage(flags: UInt8, serial: UInt32 = 9, sequence: UInt32, packets: [Data], continued: Bool = false, lastContinues: Bool = false) -> Data {
        var lacing: [UInt8] = []
        for (index, packet) in packets.enumerated() {
            var n = packet.count
            while n >= 255 { lacing.append(255); n -= 255 }
            if !(lastContinues && index == packets.count - 1) { lacing.append(UInt8(n)) } else if n > 0 { lacing.append(UInt8(n)) }
        }
        var page = Data("OggS".utf8) + Data([0, flags | (continued ? 1 : 0)]) + Data(count: 8)
        page += withUnsafeBytes(of: serial.littleEndian) { Data($0) } + withUnsafeBytes(of: sequence.littleEndian) { Data($0) } + Data(count: 4)
        page += Data([UInt8(lacing.count)]) + Data(lacing)
        for packet in packets { page += packet }
        return page
    }
    func le32(_ value: UInt32) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
    let head = Data("OpusHead".utf8) + Data([1, 2, 56, 1]) + le32(48000) + Data([0, 0, 0])
    let vendor = Data("test".utf8)
    let comments = [Data("ARTIST=Band".utf8), Data("TITLE=Song".utf8)]
    var tags = Data("OpusTags".utf8) + le32(UInt32(vendor.count)) + vendor + le32(UInt32(comments.count))
    for comment in comments { tags += le32(UInt32(comment.count)) + comment }
    let big = Data([0xFC]) + Data(repeating: 7, count: 400)          // a 401-byte packet needs two lacing values
    let stream = oggPage(flags: 2, sequence: 0, packets: [head]) + oggPage(flags: 0, sequence: 1, packets: [tags]) + oggPage(flags: 0, sequence: 2, packets: [Data([0xFC, 1, 2, 3]), big])
    let recorder = Recorder()
    let ogg = OggOpusDemuxer(sink: recorder)
    var offset = 0
    while offset < stream.count { ogg.feed(stream[offset..<min(stream.count, offset + 7)]); offset += 7 }
    try check(recorder.formats.count == 1 && recorder.formats[0].mFormatID == kAudioFormatOpus && recorder.formats[0].mChannelsPerFrame == 2 && recorder.formats[0].mSampleRate == 48000, "Ogg Opus header becomes an Opus stream format")
    try check(recorder.titles == ["Band - Song"], "OpusTags artist and title become the station title")
    try check(recorder.packets.count == 2 && recorder.packets.allSatisfy { $0.frames == 960 } && recorder.packets[1].data.count == 401, "Ogg packets reassemble across lacing values and arbitrary chunking")
    let unknownSink = Recorder()
    OggOpusDemuxer(sink: unknownSink).feed(oggPage(flags: 2, sequence: 0, packets: [Data([0x7F]) + Data("FLAC".utf8) + Data(count: 20)]))
    try check(unknownSink.failures.first?.hasPrefix("\u{1}") == true && unknownSink.failures.first?.contains("Opus or Vorbis") == true, "Other Ogg codecs fail permanently with a clear message")
    let mixedSink = Recorder()
    let mixed = OggDemuxer(sink: mixedSink)
    mixed.feed(oggPage(flags: 2, sequence: 0, packets: [head]))
    mixed.feed(oggPage(flags: 2, serial: 10, sequence: 0, packets: [Data([1]) + Data("vorbis".utf8) + Data(count: 20)]))
    try check(mixedSink.failures.first?.contains("changed its audio format") == true, "A chained stream that switches codec is rejected")
    var vorbisComment = Data([3]) + Data("vorbis".utf8) + le32(4) + Data("test".utf8) + le32(2)
    for comment in comments { vorbisComment += le32(UInt32(comment.count)) + comment }
    try check(OpusInfo.comments(in: vorbisComment, after: 7) == "Band - Song", "Vorbis comment headers yield artist and title")
    let ffmpeg = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"].first { FileManager.default.isExecutableFile(atPath: $0) }
    if let ffmpeg {
        let wavURL = root.appendingPathComponent("tone.wav"), oggURL = root.appendingPathComponent("tone.ogg")
        var wav = Data("RIFF".utf8) + le32(36 + 44100 * 4) + Data("WAVEfmt ".utf8) + le32(16) + Data([1, 0, 2, 0]) + le32(44100) + le32(44100 * 4) + Data([4, 0, 16, 0]) + Data("data".utf8) + le32(44100 * 4)
        for n in 0..<44100 { let v = Int16(8000 * sin(2 * Double.pi * 1000 * Double(n) / 44100)); for _ in 0..<2 { wav += withUnsafeBytes(of: v.littleEndian) { Data($0) } } }
        try wav.write(to: wavURL)
        let encoder = Process(); encoder.executableURL = URL(fileURLWithPath: ffmpeg)
        encoder.arguments = ["-loglevel", "error", "-y", "-i", wavURL.path, "-c:a", "vorbis", "-strict", "-2", "-metadata", "title=Tone", "-metadata", "artist=Test", oggURL.path]
        try encoder.run(); encoder.waitUntilExit()
        let ogg = try Data(contentsOf: oggURL)
        let vorbisSink = Recorder()
        let vorbisDemuxer = OggDemuxer(sink: vorbisSink)
        var at = 0
        while at < ogg.count { vorbisDemuxer.feed(ogg[at..<min(ogg.count, at + 777)]); at += 777 }
        let frames = vorbisSink.packets.reduce(0) { $0 + Int($1.frames) }
        try check(vorbisSink.formats.count == 1 && vorbisSink.formats[0].mFormatID == kAudioFormatLinearPCM && vorbisSink.formats[0].mChannelsPerFrame == 2 && vorbisSink.formats[0].mSampleRate == 44100, "Ogg Vorbis opens as 16-bit PCM at the stream’s rate")
        try check(abs(frames - 44100) < 2200 && vorbisSink.titles == ["Test - Tone"] && vorbisSink.failures.isEmpty, "Ogg Vorbis decodes about one second of audio with its title (\(frames) frames)")
        let samples = vorbisSink.packets.dropFirst(4).flatMap { packet in packet.data.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) } }
        let peak = samples.map { abs(Int($0)) }.max() ?? 0
        try check(peak > 6000 && peak < 10000, "Decoded Vorbis keeps the source amplitude (peak \(peak))")
    } else { print("SKIP: Ogg Vorbis decode (ffmpeg not installed)") }

    // HLS playlists, TS, ID3, AES
    let hlsBase = URL(string: "https://radio.example/live/index.m3u8")!
    let master = "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1200000,CODECS=\"avc1.4d401f,mp4a.40.2\"\nvideo.m3u8\n#EXT-X-STREAM-INF:BANDWIDTH=64000,CODECS=\"mp4a.40.5\"\nlo.m3u8\n#EXT-X-STREAM-INF:BANDWIDTH=128000,CODECS=\"mp4a.40.2\"\nhttps://cdn.example/hi.m3u8\n#EXT-X-STREAM-INF:BANDWIDTH=320000,CODECS=\"mp4a.40.2\"\nhuge.m3u8\n"
    guard case .master(let variants) = try HLSPlaylist.parse(master, base: hlsBase) else { throw RadioError.message("FAIL: master playlist") }
    try check(variants.count == 4 && HLSPlaylist.choose(variants).url.absoluteString == "https://cdn.example/hi.m3u8", "HLS picks the best audio variant at or below 256 kb/s and ignores video")
    let media = "#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXT-X-MEDIA-SEQUENCE:100\n#EXT-X-KEY:METHOD=AES-128,URI=\"key.bin\"\n#EXTINF:6.0,\nseg100.ts\n#EXTINF:6.0,\nseg101.ts\n"
    guard case .media(let parsed) = try HLSPlaylist.parse(media, base: hlsBase) else { throw RadioError.message("FAIL: media playlist") }
    try check(parsed.segments.map { $0.sequence } == [100, 101] && parsed.segments[0].url.absoluteString == "https://radio.example/live/seg100.ts" && parsed.targetDuration == 6 && !parsed.ended, "HLS media playlist resolves segment URLs and sequence numbers")
    try check(HLSPlaylist.iv(for: parsed.segments[1]) == Data(repeating: 0, count: 15) + Data([101]), "HLS default IV is the segment sequence number")
    guard case .media(let fragmented) = try HLSPlaylist.parse("#EXTM3U\n#EXT-X-MAP:URI=\"init.mp4\"\n#EXTINF:6,\na.m4s\n", base: hlsBase),
          case .media(let sampleAES) = try HLSPlaylist.parse("#EXTM3U\n#EXT-X-KEY:METHOD=SAMPLE-AES,URI=\"k\"\n#EXTINF:6,\na.ts\n", base: hlsBase) else { throw RadioError.message("FAIL: unsupported playlists") }
    try check(fragmented.unsupported != nil && sampleAES.unsupported != nil, "Fragmented MP4 and SAMPLE-AES are reported as unsupported")
    try rejects("Reject non-playlist text as HLS") { _ = try HLSPlaylist.parse("hello", base: hlsBase) }

    func tsPacket(pid: Int, start: Bool, payload: Data, counter: Int) -> Data {
        var packet = Data([0x47, (start ? 0x40 : 0) | UInt8(pid >> 8), UInt8(pid & 0xFF)])
        let room = 184
        if payload.count < room {
            let pad = room - payload.count
            packet.append(0x30 | UInt8(counter & 15)); packet.append(UInt8(pad - 1))
            if pad >= 2 { packet.append(0); packet.append(Data(repeating: 0xFF, count: pad - 2)) }
        } else { packet.append(0x10 | UInt8(counter & 15)) }
        return packet + payload
    }
    let patSection = Data([0x00, 0xB0, 13, 0, 1, 0xC1, 0, 0, 0, 1, 0xF0, 0x00, 0, 0, 0, 0])
    let pmtSection = Data([0x02, 0xB0, 18, 0, 1, 0xC1, 0, 0, 0xE1, 0x00, 0xF0, 0, 0x0F, 0xE1, 0x00, 0xF0, 0, 0, 0, 0, 0])
    let adts = Data([0xFF, 0xF1, 0x50, 0x80, 0x01, 0x3F, 0xFC, 0x21, 0x22, 0x23])
    let pes = Data([0, 0, 1, 0xC0, 0, 18, 0x80, 0x00, 0]) + adts + adts
    let segment = tsPacket(pid: 0, start: true, payload: Data([0]) + patSection, counter: 0) + tsPacket(pid: 0x1000, start: true, payload: Data([0]) + pmtSection, counter: 0) + tsPacket(pid: 0x100, start: true, payload: pes, counter: 0)
    try check(TSDemuxer.kind(of: segment) == .transport, "TS segments are recognized by their sync byte")
    let demuxed = TSDemuxer.audio(from: segment)
    try check(demuxed?.audio == adts + adts, "TS demux finds the audio PID through PAT and PMT and strips PES headers")
    try check(TSDemuxer.kind(of: Data([0, 0, 0, 0x20]) + Data("ftypiso5".utf8)) == .fragmentedMP4 && TSDemuxer.kind(of: Data([0xFF, 0xF1])) == .packedAudio, "Segment kinds: fragmented MP4 and packed ADTS")
    let frame = Data("TIT2".utf8) + Data([0, 0, 0, 6, 0, 0, 3]) + Data("Hello".utf8)
    let id3 = Data("ID3".utf8) + Data([4, 0, 0, 0, 0, 0, UInt8(frame.count)]) + frame
    let stripped = TSDemuxer.stripID3(id3 + adts)
    try check(stripped.audio == adts && stripped.title == "Hello", "Packed-audio ID3 tags are removed and their title is read")
    var key = Data(repeating: 3, count: 16), iv = Data(repeating: 5, count: 16)
    let plain = Data((0..<64).map { UInt8($0) }) + Data(repeating: 16, count: 16)   // already PKCS#7-padded
    var encrypted = Data(count: plain.count + 16); var produced = 0
    let cryptStatus = encrypted.withUnsafeMutableBytes { out in plain.withUnsafeBytes { input in key.withUnsafeBytes { k in iv.withUnsafeBytes { v in
        CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES128), 0, k.baseAddress, 16, v.baseAddress, input.baseAddress, plain.count, out.baseAddress, out.count, &produced) } } } }
    try check(cryptStatus == kCCSuccess && HLSSource.decrypt(encrypted.prefix(produced), key: key, iv: iv) == Data((0..<64).map { UInt8($0) }), "HLS AES-128 segments decrypt and drop PKCS#7 padding")
    key = Data(); iv = Data()
    // Window snapping
    let screenRect = NSRect(x: 0, y: 0, width: 1000, height: 800), anchor = NSRect(x: 300, y: 400, width: 550, height: 232)
    let nearBelow = NSRect(x: 306, y: 400 - 232 - 6, width: 550, height: 232)
    let docked = PlayerWindow.snapped(nearBelow, to: [anchor], screen: screenRect)
    try check(docked.minX == 300 && docked.maxY == anchor.minY, "A window dropped near another snaps flush under it")
    try check(PlayerWindow.snapped(NSRect(x: 5, y: 300, width: 100, height: 50), to: [], screen: screenRect).minX == 0, "A window near the screen edge snaps to it")
    try check(PlayerWindow.snapped(NSRect(x: 400, y: 100, width: 100, height: 50), to: [anchor], screen: screenRect).origin == NSPoint(x: 400, y: 100), "Distant windows do not snap")
    try check(PlayerWindow.touching(anchor, NSRect(x: 300, y: 168, width: 550, height: 232)) && !PlayerWindow.touching(anchor, NSRect(x: 300, y: 100, width: 550, height: 232)), "Docked windows are detected by touching edges")
    // Jump to Station matching
    let jumpList = [Station(name: "Groove Salad", address: "https://a.example/gs"), Station(name: "Deep Space One", address: "https://a.example/ds"), Station(name: "Space Station Soma", address: "https://a.example/sss")]
    try check(StationSearch.match("space", in: jumpList).map(\.name) == ["Space Station Soma", "Deep Space One"], "Jump matching ranks names that start with the text first")
    try check(StationSearch.match("station soma", in: jumpList).map(\.name) == ["Space Station Soma"], "Jump matching requires every typed word")
    try check(StationSearch.match("", in: jumpList).count == 3 && StationSearch.match("zzz", in: jumpList).isEmpty, "Jump matching: empty query lists all, no match lists none")
    // Loudness leveler
    func leveled(amplitude: Float, enabled: Bool, seconds: Double = 40) -> (peak: Float, gain: Double) {
        let level = rp_eq_create()!
        defer { rp_eq_destroy(level) }
        rp_eq_prepare(level, 44100); rp_level_set(level, enabled ? 1 : 0)
        var peak: Float = 0, phase = 0.0
        for block in 0..<Int(seconds * 44100 / 512) {
            var buffer = (0..<512).map { _ -> Float in phase += 2 * Double.pi * 440 / 44100; return amplitude * Float(sin(phase)) }
            rp_eq_process(level, &buffer, 512, 1, 0)
            if block > Int(seconds * 44100 / 512) - 20 { peak = max(peak, buffer.map(abs).max() ?? 0) }
        }
        return (peak, rp_level_db(level))
    }
    let quiet = leveled(amplitude: 0.02, enabled: true), loud = leveled(amplitude: 0.95, enabled: true), off = leveled(amplitude: 0.02, enabled: false)
    try check(quiet.gain > 6 && quiet.gain <= 10.01 && quiet.peak > 0.02 * 2, "Leveler raises a quiet station (\(String(format: "%+.1f", quiet.gain)) dB)")
    try check(loud.gain < -3 && loud.peak < 0.9, "Leveler lowers a loud station and stays below full scale (\(String(format: "%+.1f", loud.gain)) dB)")
    try check(off.gain == 0 && abs(off.peak - 0.02) < 0.0005, "Leveler off leaves audio untouched")
    print("\(checks) checks passed.")
} catch {
    fputs("\(error.localizedDescription)\n", stderr)
    exit(1)
}
