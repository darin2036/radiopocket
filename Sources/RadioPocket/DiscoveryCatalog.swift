import Foundation

/// Shared vocabulary for preferences, deterministic matching and optional query interpretation.
/// Display names are independent of source-native tags and of ranking/presentation policy.
enum DiscoveryCatalog {
    struct GenreGroup { var name: String; var values: [String] }
    static let groups: [GenreGroup] = [
        .init(name: "Calm & focus", values: ["ambient", "chill", "downtempo", "lo-fi", "instrumental", "piano", "acoustic", "lounge", "new age", "meditation"]),
        .init(name: "Jazz, soul & blues", values: ["jazz", "smooth jazz", "bebop", "swing", "fusion", "blues", "soul", "neo soul", "r&b", "funk"]),
        .init(name: "Guitars & roots", values: ["rock", "classic rock", "alternative", "indie", "folk", "americana", "country", "bluegrass", "punk", "metal", "post rock"]),
        .init(name: "Electronic", values: ["electronic", "house", "deep house", "techno", "trance", "drum and bass", "breakbeat", "dubstep", "synthwave", "disco", "dance", "electro"]),
        .init(name: "Around the world", values: ["world", "reggae", "dub", "ska", "afrobeat", "afropop", "latin", "salsa", "bossa nova", "samba", "flamenco", "celtic", "bollywood", "k-pop", "j-pop"]),
        .init(name: "Pop, classical & beyond", values: ["pop", "indie pop", "hip hop", "classical", "baroque", "opera", "soundtrack", "oldies", "60s", "70s", "80s", "90s", "00s", "music"])
    ]
    static let genres = groups.flatMap(\.values)
    static let aliases = ["lofi": "lo-fi", "lo fi": "lo-fi", "hiphop": "hip hop", "hip-hop": "hip hop", "rnb": "r&b", "rhythm and blues": "r&b", "dnb": "drum and bass", "drum & bass": "drum and bass", "chillout": "chill", "chill out": "chill", "kpop": "k-pop", "jpop": "j-pop", "post-rock": "post rock", "neosoul": "neo soul", "synth pop": "synthwave"]
    static func words(_ value: String) -> String {
        StationSearch.fold(value).components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
    }
    static func matches(_ text: String) -> Set<String> {
        let haystack = " " + words(text) + " "
        var found = Set(genres.filter { haystack.contains(" " + words($0) + " ") })
        for (alias, genre) in aliases where haystack.contains(" " + words(alias) + " ") { found.insert(genre) }
        return found
    }
    struct Language {
        var code: String; var name: String; var aliases: [String]
    }
    static let languages: [Language] = [
        .init(code: "en", name: "English", aliases: ["eng"]), .init(code: "es", name: "Spanish", aliases: ["spa", "espanol"]),
        .init(code: "fr", name: "French", aliases: ["fra", "fre", "francais"]), .init(code: "de", name: "German", aliases: ["deu", "ger", "deutsch"]),
        .init(code: "it", name: "Italian", aliases: ["ita", "italiano"]), .init(code: "pt", name: "Portuguese", aliases: ["por", "portugues"]),
        .init(code: "nl", name: "Dutch", aliases: ["nld", "dut"]), .init(code: "ar", name: "Arabic", aliases: ["ara"]),
        .init(code: "zh", name: "Chinese", aliases: ["zho", "chi", "mandarin", "cantonese"]), .init(code: "ja", name: "Japanese", aliases: ["jpn"]),
        .init(code: "ko", name: "Korean", aliases: ["kor"]), .init(code: "hi", name: "Hindi", aliases: ["hin"]),
        .init(code: "bn", name: "Bengali", aliases: ["ben"]), .init(code: "ur", name: "Urdu", aliases: ["urd"]),
        .init(code: "ru", name: "Russian", aliases: ["rus"]), .init(code: "uk", name: "Ukrainian", aliases: ["ukr"]),
        .init(code: "pl", name: "Polish", aliases: ["pol"]), .init(code: "cs", name: "Czech", aliases: ["ces", "cze"]),
        .init(code: "el", name: "Greek", aliases: ["ell", "gre"]), .init(code: "tr", name: "Turkish", aliases: ["tur"]),
        .init(code: "sv", name: "Swedish", aliases: ["swe"]), .init(code: "no", name: "Norwegian", aliases: ["nor", "nob", "nno"]),
        .init(code: "da", name: "Danish", aliases: ["dan"]), .init(code: "fi", name: "Finnish", aliases: ["fin"]),
        .init(code: "ro", name: "Romanian", aliases: ["ron", "rum"]), .init(code: "hu", name: "Hungarian", aliases: ["hun"]),
        .init(code: "he", name: "Hebrew", aliases: ["heb"]), .init(code: "id", name: "Indonesian", aliases: ["ind"]),
        .init(code: "th", name: "Thai", aliases: ["tha"]), .init(code: "vi", name: "Vietnamese", aliases: ["vie"]),
        .init(code: "sw", name: "Swahili", aliases: ["swa"]), .init(code: "ta", name: "Tamil", aliases: ["tam"])
    ].sorted { $0.name < $1.name }
    static func languageCodes(_ text: String) -> [String] {
        let tokens = Set(text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).map { StationSearch.fold($0) })
        return languages.filter { !tokens.isDisjoint(with: Set([$0.code, $0.name.lowercased()] + $0.aliases)) }.map(\.code)
    }
    static func languageName(_ code: String) -> String { languages.first { $0.code == code }?.name ?? code }
}

struct DiscoveryPreferences {
    var genres: [String] = []
    var languages: [String] = []
    var includeUnknownLanguage = true
    var useHistory = true
    var useAI = false
    var checkAvailability = true
    var showArtwork = true
    var moodCity: MoodCity?
    var weatherPromptHandled = false
    init(state: Library.State) {
        moodCity = state.moodCity; weatherPromptHandled = state.moodWeatherPromptHandled == true
        genres = (state.discoveryInterests ?? []).filter(DiscoveryCatalog.genres.contains)
        languages = (state.discoveryLanguages ?? []).filter { code in DiscoveryCatalog.languages.contains { $0.code == code } }
        includeUnknownLanguage = state.discoveryIncludeUnknownLanguage != false
        checkAvailability = state.discoveryAvailabilityChecks != false
        useHistory = state.discoveryPersonalization != false; useAI = state.discoveryAI == true; showArtwork = state.discoveryArtwork != false
    }
    func apply(to state: inout Library.State) {
        state.moodCity = moodCity; state.moodWeatherPromptHandled = weatherPromptHandled
        state.discoveryInterests = genres; state.discoveryLanguages = languages; state.discoveryIncludeUnknownLanguage = includeUnknownLanguage
        state.discoveryAvailabilityChecks = checkAvailability
        state.discoveryPersonalization = useHistory; state.discoveryAI = useAI; state.discoveryArtwork = showArtwork
    }
}

/// Current preferences only, not an event log. No transmission or placement semantics.
enum DiscoveryFeedback {
    static func keys(for station: RadioListing) -> [String] {
        ["url:" + DiscoveryIndex.endpointKey(station.address), "station:" + station.id]
    }
    static func vote(for station: RadioListing, in values: [String: Int], legacy: Set<String> = []) -> Int {
        for key in keys(for: station) { if let value = values[key], value == 1 || value == -1 || value == 0 { return value } }
        return legacy.contains(DiscoveryIndex.endpointKey(station.address)) ? -1 : 0
    }
    static func toggle(_ requested: Int, station: RadioListing, state: inout Library.State) {
        guard requested == 1 || requested == -1 else { return }
        var values = state.discoveryFeedback ?? [:]
        let next = vote(for: station, in: values, legacy: Set(state.discoveryDismissed ?? [])) == requested ? 0 : requested
        for key in keys(for: station) { values[key] = next }
        state.discoveryDismissed?.removeAll { $0 == DiscoveryIndex.endpointKey(station.address) }
        if values.count > 4000 {
            let keep = Set(keys(for: station))
            for key in values.keys.sorted().filter({ !keep.contains($0) }).prefix(values.count - 4000) { values.removeValue(forKey: key) }
        }
        state.discoveryFeedback = values
    }
}

/// Relevance and local feedback remain separate inputs. No presentation block owns ranking rules.
enum DiscoveryRanking {
    static func score(relevance: Double, quality: Int, variation: Double, feedback: Int) -> Double {
        let base = relevance + Double(quality) * 0.15 + variation
        return base + (feedback > 0 ? 12 : feedback < 0 ? -24 : 0)
    }
}
