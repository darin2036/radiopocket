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
    // Normalize the fixed vocabulary once, rather than ~90 times for each station comparison.
    private static let genrePhrases: [String: Set<String>] = {
        var result: [String: Set<String>] = [:]
        for genre in genres { result[words(genre), default: []].insert(genre) }
        for (alias, genre) in aliases { result[words(alias), default: []].insert(genre) }
        return result
    }()
    private static let longestPhrase = genrePhrases.keys.map { $0.split(separator: " ").count }.max() ?? 1
    static func matches(_ text: String) -> Set<String> {
        let tokens = words(text).split(separator: " ")
        var found = Set<String>()
        for start in tokens.indices {
            var phrase = ""
            for end in start..<min(tokens.count, start + longestPhrase) {
                if end > start { phrase += " " }
                phrase += tokens[end]
                if let matches = genrePhrases[phrase] { found.formUnion(matches) }
            }
        }
        return found
    }
    /// Descriptive wording (tempo, mood, activity) that implies genres, so searches work without AI or when it is unavailable.
    private static let vibes: [(phrases: [String], genres: [String])] = [
        (["high bpm", "fast tempo", "fast paced", "high tempo", "upbeat", "high energy", "energetic", "fast", "club", "rave", "workout", "gym", "running", "pump up", "hype"], ["techno", "house", "drum and bass", "trance", "dance", "electro", "dubstep"]),
        (["edm", "electronica", "beats"], ["electronic", "house", "techno", "trance", "dance"]),
        (["low bpm", "slow tempo", "slow", "relaxing", "relax", "calm", "mellow", "sleep", "unwind", "soothing", "peaceful"], ["ambient", "chill", "downtempo", "new age", "meditation", "piano"]),
        (["study", "studying", "focus", "concentrate", "concentration", "work music", "background"], ["lo-fi", "ambient", "instrumental", "classical", "piano"]),
        (["party", "dance floor", "dancing"], ["dance", "house", "disco", "pop", "electro"]),
        (["romantic", "dinner", "cocktail", "date night"], ["jazz", "bossa nova", "lounge", "soul", "smooth jazz"]),
        (["heavy", "aggressive", "loud"], ["metal", "punk", "rock"]),
        (["happy", "sunny", "feel good", "summer"], ["reggae", "pop", "funk", "indie pop", "latin"]),
        (["sad", "melancholy", "moody", "rainy"], ["folk", "blues", "indie", "piano", "acoustic"]),
        (["throwback", "nostalgic", "retro"], ["oldies", "disco", "80s", "70s", "90s"])
    ]
    private static let fillers: Set<String> = ["music", "station", "stations", "radio", "song", "songs", "some", "something", "with", "for", "and", "a", "an", "the", "me", "i", "want", "play", "like", "to", "listen", "that", "is", "of", "in", "good", "stuff", "sounds"]
    /// Genres implied by descriptive words, plus whatever text is left over for literal matching.
    static func interpretVibes(_ text: String) -> (genres: [String], remainder: String) {
        var padded = " " + words(text) + " "
        var found: [String] = []
        for vibe in vibes {
            for phrase in vibe.phrases where padded.contains(" " + phrase + " ") {
                padded = padded.replacingOccurrences(of: " " + phrase + " ", with: " ")
                for genre in vibe.genres where !found.contains(genre) { found.append(genre) }
            }
        }
        guard !found.isEmpty else { return ([], text) }
        let rest = padded.split(separator: " ").map(String.init).filter { !fillers.contains($0) }
        return (found, rest.joined(separator: " "))
    }
    /// Internet TV categories, with the wording channel lists use for each. TV Discover matches these instead of music genres.
    private static let tvTopics: [(name: String, phrases: [String])] = [
        ("animation", ["animation", "animated", "anime", "cartoon", "cartoons"]),
        ("classic", ["classic", "classics", "retro", "vintage"]),
        ("comedy", ["comedy", "comedies", "sitcom", "sitcoms", "stand up", "humor"]),
        ("cooking", ["cooking", "chef", "food", "recipes", "kitchen"]),
        ("culture", ["culture", "cultural", "arts", "history"]),
        ("documentary", ["documentary", "documentaries", "nature", "science", "wildlife"]),
        ("drama", ["drama", "dramas", "telenovela", "soap"]),
        ("education", ["education", "educational", "learning", "school"]),
        ("entertainment", ["entertainment", "variety", "reality", "celebrity"]),
        ("family", ["family"]),
        ("kids", ["kids", "kid", "children", "childrens", "junior", "preschool"]),
        ("lifestyle", ["lifestyle", "fashion", "garden", "wellness", "beauty", "health"]),
        ("movies", ["movie", "movies", "film", "films", "cinema"]),
        ("music videos", ["music", "concert", "concerts", "mtv"]),
        ("series", ["series", "shows", "episodes"]),
        ("sports", ["sport", "sports", "football", "soccer", "basketball", "baseball", "hockey", "tennis", "golf", "racing", "cricket", "rugby"]),
        ("travel", ["travel", "adventure", "tourism"])
    ]
    static let tvCategories = tvTopics.map(\.name)
    static func tvMatches(_ text: String) -> Set<String> {
        let padded = " " + words(text) + " "
        return Set(tvTopics.filter { topic in topic.phrases.contains { padded.contains(" " + $0 + " ") } }.map(\.name))
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
        .init(code: "bn", name: "Bengali", aliases: ["ben", "bangla"]), .init(code: "ur", name: "Urdu", aliases: ["urd"]),
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
    /// Languages a channel name or tags state outright ("Bangla", "Espanol"), for lists that publish no language field.
    static func languageHints(_ text: String) -> Set<String> {
        let tokens = Set(words(text).split(separator: " ").map(String.init))
        return Set(languages.filter { language in !tokens.isDisjoint(with: Set([language.name.lowercased()] + language.aliases.filter { $0.count >= 5 })) }.map(\.code))
    }
    private static let nonLatinLanguages: Set<String> = ["ar", "zh", "ja", "ko", "hi", "bn", "ur", "ru", "uk", "el", "he", "th", "ta"]
    /// True when a name is written in a script none of the wanted languages use. Only judged when every wanted language is Latin-script.
    static func foreignScript(_ text: String, wanted: [String]) -> Bool {
        guard !wanted.isEmpty, wanted.allSatisfy({ !nonLatinLanguages.contains($0) }) else { return false }
        return text.unicodeScalars.contains { $0.properties.isAlphabetic && (0x0370...0x1DFF ~= $0.value || 0x3040...0xA4CF ~= $0.value || 0xAC00...0xD7AF ~= $0.value || 0xFB1D...0xFEFF ~= $0.value) }
    }
    /// The Mac's preferred languages, in order, limited to the languages Discover knows.
    static func systemLanguages(_ identifiers: [String] = Locale.preferredLanguages) -> [String] {
        var codes: [String] = []
        for identifier in identifiers {
            var code = Locale(identifier: identifier).language.languageCode?.identifier ?? ""
            if code == "nb" || code == "nn" { code = "no" }
            if languages.contains(where: { $0.code == code }), !codes.contains(code) { codes.append(code) }
        }
        return codes
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
        genres = (state.discoveryInterests ?? []).filter { DiscoveryCatalog.genres.contains($0) || DiscoveryCatalog.tvCategories.contains($0) }
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
