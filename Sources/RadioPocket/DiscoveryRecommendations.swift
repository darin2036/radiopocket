import Foundation

/// Discover is stricter than the general browser, even when its TV filters are disabled.
/// Metadata cannot certify the live broadcast; unknown categories are withheld from automatic recommendations.
enum DiscoverySafety {
    static let genres = DiscoveryCatalog.genres
    private static let sensitive = try! NSRegularExpression(pattern: #"(?i)(?<![a-z])(adult\w*|explicit\w*|uncensored|nsfw|xxx|porn\w*|sex\w*|erotic\w*|hentai|fetish|bdsm|nude\w*|naked|18\+|violence|violent|gore|horror|suicide|self.harm|hate|extremis\w*|terror\w*|gambl\w*|casino|betting|drugs?|cannabis|marijuana|politic\w*|religio\w*|news|talk)(?![a-z])"#)
    static func tokens(_ text: String) -> Set<String> {
        Set(StationSearch.fold(text).components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty })
    }
    static func interests(_ listing: RadioListing) -> Set<String> {
        DiscoveryCatalog.matches(listing.tags + " " + listing.name)
    }
    static func allows(_ listing: RadioListing) -> Bool {
        guard let url = try? StreamAddress.parse(listing.address), url.user == nil, url.password == nil else { return false }
        let text = StationSearch.fold(listing.name + " " + listing.tags + " " + (url.removingPercentEncodingString))
        guard sensitive.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) == nil,
              TVSafety.allows(title: listing.name, group: listing.tags, address: url, settings: .init(hideAdult: true, hideUnreliable: true)),
              !interests(listing).isEmpty else { return false }
        return listing.likelyPlayable
    }
}
private extension URL {
    var removingPercentEncodingString: String { absoluteString.removingPercentEncoding ?? absoluteString }
}

struct DiscoveryPick {
    var listing: RadioListing
    var reason: String
    var sources: [String]
    var fetched: Date
    var feedback: Int = 0
    var availability: DiscoveryAvailability.Evidence?
}
struct DiscoveryShelf {
    var title: String
    var subtitle: String
    var picks: [DiscoveryPick]
}
struct DiscoveryFeed {
    var shelves: [DiscoveryShelf]
    var interests: [String]
    var basis: String
    var indexed: Int
    var updated: Date?
    var moodGroups: [MoodGroup] = []
    var moodGreetings: [String] = []
}

enum DiscoveryRecommendations {
    /// Eligibility is separate from ranking: preference signals cannot bypass the quality floor.
    static let minimumQuality = 4
    static func build(records: [DiscoveryIndex.Record], recent: [Station], favorites: [Station], interests: [String], dismissed: Set<String>, personalizes: Bool, video: Bool, languages: [String] = [], includeUnknownLanguage: Bool = true, requiredGenres: [String] = [], feedback: [String: Int] = [:], availability: [String: DiscoveryAvailability.Evidence] = [:], day: Int = Int(Date().timeIntervalSince1970 / 86400)) -> DiscoveryFeed {
        let now = Date()
        let grouped = Dictionary(grouping: records, by: { DiscoveryIndex.matchKey($0.restored.address) })
        // Any conflicting sensitive metadata excludes the endpoint, not just the winning listing.
        let safe = grouped.values.filter { !Task.isCancelled && $0.allSatisfy { DiscoverySafety.allows($0.restored) } }
        let known = Dictionary(uniqueKeysWithValues: safe.compactMap { group -> (String, RadioListing)? in
            guard let first = group.first else { return nil }; return (DiscoveryIndex.matchKey(first.restored.address), first.restored)
        })
        var affinity: [String: Double] = [:]
        let explicit = interests.filter { DiscoverySafety.genres.contains($0) }
        for genre in explicit { affinity[genre, default: 0] += 12 }
        var recentGenres = Set<String>()
        var favoriteGenres = Set<String>()
        var historyMatches = 0
        if personalizes {
            for (position, station) in recent.prefix(30).enumerated() {
                let row = known[DiscoveryIndex.matchKey(station.address)] ?? RadioListing(station: station)
                guard DiscoverySafety.allows(row) else { continue }
                let tags = DiscoverySafety.interests(row)
                recentGenres.formUnion(tags)
                if !tags.isEmpty { historyMatches += 1 }
                for tag in tags { affinity[tag, default: 0] += max(1, 4 - Double(position) / 10) }
            }
        }
        for station in favorites {
            let row = known[DiscoveryIndex.matchKey(station.address)] ?? RadioListing(station: station)
            if DiscoverySafety.allows(row) {
                favoriteGenres.formUnion(DiscoverySafety.interests(row))
                for tag in DiscoverySafety.interests(row) { affinity[tag, default: 0] += 3 }
            }
        }
        let basis = !explicit.isEmpty ? "Fresh frequencies for your kind of listening" : historyMatches >= 3 ? "Inspired by your recent listening" : !affinity.isEmpty ? "A starting mix from your favorites and recent stations" : "A varied starting mix — no listening history needed"
        if affinity.isEmpty { for tag in ["ambient", "jazz", "classical", "world", "indie", "electronic"] { affinity[tag] = 1 } }
        let top = affinity.keys.sorted { affinity[$0] == affinity[$1] ? $0 < $1 : affinity[$0]! > affinity[$1]! }
        let heard = Set((personalizes ? recent : []).map { DiscoveryIndex.matchKey($0.address) })
        let saved = Set(favorites.map { DiscoveryIndex.matchKey($0.address) })
        let candidates: [DiscoveryPick] = safe.compactMap { group in
            guard !Task.isCancelled else { return nil }
            guard let entry = group.max(by: { $0.fetched < $1.fetched }) else { return nil }
            var row = entry.restored
            // Enrich presentation from matching provenance without changing station identity.
            if row.homepage.isEmpty { row.homepage = group.map { $0.restored.homepage }.first { !$0.isEmpty } ?? "" }
            if row.artworkURL == nil { row.artworkURL = group.compactMap { $0.restored.artworkURL }.first }
            let knownLanguages = Set(group.flatMap { $0.restored.languages ?? [] })
            row.languages = knownLanguages.sorted()
            if !languages.isEmpty {
                if knownLanguages.isEmpty { guard includeUnknownLanguage else { return nil } }
                else if knownLanguages.isDisjoint(with: Set(languages)) { return nil }
            }
            guard row.video == video, row.quality >= minimumQuality, availability[DiscoveryIndex.endpointKey(row.address)]?.excluded(at: now) != true else { return nil }
            if !requiredGenres.isEmpty && DiscoverySafety.interests(row).isDisjoint(with: Set(requiredGenres)) { return nil }
            let vote = DiscoveryFeedback.vote(for: row, in: feedback, legacy: dismissed)
            let reason = recommendationReason(for: row, rankedGenres: top, explicit: Set(explicit), recent: recentGenres, favorites: favoriteGenres, vote: vote)
            return DiscoveryPick(listing: row, reason: reason, sources: Array(Set(group.map(\.sourceName))).sorted(), fetched: entry.fetched, feedback: DiscoveryFeedback.vote(for: row, in: feedback, legacy: dismissed), availability: availability[DiscoveryIndex.endpointKey(row.address)])
        }
        let tagsByAddress = Dictionary(uniqueKeysWithValues: candidates.map { ($0.listing.address, DiscoverySafety.interests($0.listing)) })
        let rotationByAddress = Dictionary(uniqueKeysWithValues: candidates.map { ($0.listing.address, rotation($0.listing.address, day: day)) })
        func score(_ pick: DiscoveryPick) -> Double {
            let row = pick.listing
            let tags = tagsByAddress[row.address] ?? []
            let personalRelevance = tags.reduce(0.0) { $0 + (affinity[$1] ?? 0) }
            // Mood fit leads; personal taste breaks ties among suitable stations.
            let matches = tags.intersection(requiredGenres).count
            let moodFit = Double(matches) / Double(max(1, tags.count))
            let relevance = requiredGenres.isEmpty ? personalRelevance : moodFit * 40 + min(personalRelevance, 10)
            return DiscoveryRanking.score(relevance: relevance, quality: row.quality, variation: Double((rotationByAddress[row.address] ?? 0) % 1000) / 1000, feedback: pick.feedback) + (pick.availability?.boost(at: now) ?? 0)
        }
        let scores = Dictionary(uniqueKeysWithValues: candidates.map { ($0.listing.address, score($0)) })
        let ordered = candidates.sorted { let a = scores[$0.listing.address]!, b = scores[$1.listing.address]!; return a == b ? $0.listing.address < $1.listing.address : a > b }
        var used = Set<String>()
        func shelf(_ title: String, _ subtitle: String, _ pool: [DiscoveryPick]) -> DiscoveryShelf? {
            var hosts: [String: Int] = [:], picks: [DiscoveryPick] = []
            for pick in pool {
                let key = DiscoveryIndex.matchKey(pick.listing.address), host = URL(string: key)?.host ?? key
                guard !used.contains(key), hosts[host, default: 0] < 2 else { continue }
                used.insert(key); hosts[host, default: 0] += 1; picks.append(pick)
                if picks.count == 6 { break }
            }
            return picks.isEmpty ? nil : DiscoveryShelf(title: title, subtitle: subtitle, picks: picks)
        }
        var shelves: [DiscoveryShelf] = []
        if let section = shelf("Your next frequency", basis, ordered.filter { $0.feedback >= 0 && !heard.contains(DiscoveryIndex.matchKey($0.listing.address)) && !saved.contains(DiscoveryIndex.matchKey($0.listing.address)) }) { shelves.append(section) }
        let unexpected = candidates.sorted { a, b in
            let av = a.availability?.boost(at: now) ?? 0, bv = b.availability?.boost(at: now) ?? 0
            if av != bv { return av > bv }
            if a.feedback != b.feedback { return a.feedback > b.feedback }
            return rotationByAddress[a.listing.address]! < rotationByAddress[b.listing.address]!
        }
        if let section = shelf("Beyond your usual", "Different sounds, refreshed each day on this device", unexpected.filter { $0.feedback >= 0 && (tagsByAddress[$0.listing.address] ?? []).isDisjoint(with: Set(top.prefix(2))) }) { shelves.append(section) }
        if let section = shelf("Worth another listen", "Familiar stations from your local library", ordered.filter { $0.feedback >= 0 && (heard.contains(DiscoveryIndex.matchKey($0.listing.address)) || saved.contains(DiscoveryIndex.matchKey($0.listing.address))) }) { shelves.append(section) }
        if let section = shelf("Around the dial", "More from your enabled directories", unexpected.filter { $0.feedback >= 0 }) { shelves.append(section) }
        if let section = shelf("Further down your dial", "Lower priority from your feedback, still here to explore", ordered.filter { $0.feedback < 0 }) { shelves.append(section) }
        return DiscoveryFeed(shelves: shelves, interests: Array(top.prefix(5)), basis: basis, indexed: records.count, updated: records.map(\.fetched).max())
    }
    /// Explain the actual ranking signals without inventing programming or listening habits.
    static func recommendationReason(for row: RadioListing, rankedGenres: [String], explicit: Set<String>, recent: Set<String>, favorites: Set<String>, vote: Int) -> String {
        if vote > 0 { return "You gave this station a thumbs up" }
        if vote < 0 { return "Shown less often because of your thumbs down" }
        let genres = DiscoverySafety.interests(row).subtracting(["music"])
        let ranked = rankedGenres.filter { genres.contains($0) }
        if let genre = ranked.first(where: explicit.contains) {
            return genre.capitalized + " that matches your chosen interests"
        }
        if let genre = ranked.first(where: favorites.contains) {
            return genre.capitalized + ", like stations in your favorites"
        }
        if let genre = ranked.first(where: recent.contains) {
            return genre.capitalized + ", building on your recent listening"
        }
        if let genre = genres.sorted(by: { $0.count == $1.count ? $0 < $1 : $0.count > $1.count }).first {
            return genre.capitalized + " to explore beyond your usual mix"
        }
        return "An exploration pick with a " + String(row.quality) + "-star stream quality rating"
    }
    private static func rotation(_ text: String, day: Int) -> UInt64 {
        (text + "|\(day)").utf8.reduce(UInt64(14695981039346656037)) { ($0 ^ UInt64($1)) &* 1099511628211 }
    }
}

/// Ephemeral station collections: no hosted playlists, generated station identities or schedule claims.
enum MoodCuration {
    struct Moment {
        let day: Int
        let period: String
        let weekend: Bool
        let weekday: Int
        let label: String
        let occasion: String?
        func greeting(name: String = "") -> String {
            let salutation = period == "Morning" ? "Good morning" : period == "Afternoon" ? "Good afternoon" : "Good evening"
            let clean = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(30))
            return salutation + (clean.isEmpty ? "" : ", " + clean)
        }
        var key: String { "\(day)-\(period)" }
        init(date: Date = Date(), calendar: Calendar = .current) {
            var occasions = Calendar(identifier: .gregorian); occasions.timeZone = calendar.timeZone
            let month = occasions.component(.month, from: date), dayOfMonth = occasions.component(.day, from: date)
            // Calendar occasions are context, never an assumption that the listener celebrates them.
            occasion = ["1-1": "New Year's Day", "2-14": "Valentine's Day", "10-31": "Halloween", "12-25": "Christmas Day", "12-31": "New Year's Eve"]["\(month)-\(dayOfMonth)"]
            let hour = calendar.component(.hour, from: date)
            period = hour < 5 ? "Late night" : hour < 12 ? "Morning" : hour < 17 ? "Afternoon" : hour < 22 ? "Evening" : "Late night"
            weekend = calendar.isDateInWeekend(date)
            weekday = calendar.component(.weekday, from: date)
            day = Int(calendar.startOfDay(for: date).timeIntervalSince1970 / 86400)
            let formatter = DateFormatter(); formatter.calendar = calendar; formatter.timeZone = calendar.timeZone; formatter.dateFormat = "EEEE"
            label = formatter.string(from: date) + " · " + period.lowercased()
        }
    }
    struct Theme {
        let title: String
        let genres: [String]
    }
    static func themes(for moment: Moment, weather: MoodWeather.Kind? = nil) -> [Theme] {
        var themes = scheduledThemes(for: moment)
        switch weather {
        case .rain: themes.insert(.init(title: "A rainy-day retreat", genres: ["folk", "lo-fi", "jazz", "acoustic", "piano", "ambient"]), at: 0)
        case .snow: themes.insert(.init(title: "Snow day, slow day", genres: ["classical", "piano", "folk", "ambient"]), at: 0)
        case .cloudy: themes.insert(.init(title: "Under cloudy skies", genres: ["indie", "chill", "soul", "downtempo"]), at: 0)
        default: break
        }
        return themes
    }
    private static func scheduledThemes(for moment: Moment) -> [Theme] {
        let calm = Theme(title: "Slow things down", genres: ["ambient", "chill", "downtempo", "piano", "meditation"])
        let focus = Theme(title: "Find your focus", genres: ["lo-fi", "instrumental", "classical", "ambient", "post rock"])
        let energy = Theme(title: "Turn up the energy", genres: ["funk", "dance", "pop", "rock", "disco", "afrobeat"])
        switch moment.period {
        case "Morning": return [.init(title: moment.weekend ? "A slow weekend morning" : "Ease into your morning", genres: ["acoustic", "folk", "jazz", "soul", "bossa nova"]), moment.weekend ? energy : focus, calm]
        case "Afternoon": return [.init(title: moment.weekend ? "Weekend wandering" : "An afternoon lift", genres: ["indie", "world", "reggae", "indie pop", "soul"]), energy, focus]
        case "Evening": return [.init(title: moment.weekend ? "Weekend after hours" : "Leave the day behind", genres: moment.weekend ? ["house", "disco", "funk", "dance", "soul"] : ["jazz", "lounge", "soul", "downtempo"]), .init(title: "Dinner with a soundtrack", genres: ["jazz", "bossa nova", "acoustic", "smooth jazz"]), calm]
        default: return [.init(title: "The late-night dial", genres: ["ambient", "downtempo", "chill", "lo-fi", "deep house"]), calm, focus]
        }
    }
    static func build(records: [DiscoveryIndex.Record], state: Library.State, moment: Moment, themes: [Theme], availability: [String: DiscoveryAvailability.Evidence] = [:]) -> DiscoveryFeed {
        var used = Set<String>()
        var shelves: [DiscoveryShelf] = []
        for theme in themes {
            if Task.isCancelled { break }
            let remaining = records.filter { !used.contains(DiscoveryIndex.matchKey($0.restored.address)) }
            let feed = DiscoveryRecommendations.build(records: remaining, recent: state.recentStations ?? [], favorites: state.favorites, interests: state.discoveryInterests ?? [], dismissed: Set(state.discoveryDismissed ?? []), personalizes: state.discoveryPersonalization != false, video: false, languages: state.discoveryLanguages ?? [], includeUnknownLanguage: state.discoveryIncludeUnknownLanguage != false, requiredGenres: theme.genres, feedback: state.discoveryFeedback ?? [:], availability: availability, day: moment.day)
            let picks = feed.shelves.flatMap(\.picks).filter { $0.feedback >= 0 }.filter { !used.contains(DiscoveryIndex.matchKey($0.listing.address)) }.prefix(6).map { pick -> DiscoveryPick in
                var result = pick
                let genre = theme.genres.first { DiscoverySafety.interests(pick.listing).contains($0) } ?? "music"
                result.reason = genre.capitalized + " for this moment"; return result
            }
            used.formUnion(picks.map { DiscoveryIndex.matchKey($0.listing.address) })
            if !picks.isEmpty { shelves.append(DiscoveryShelf(title: theme.title, subtitle: moment.label + " · From your directories", picks: picks)) }
        }
        return DiscoveryFeed(shelves: shelves, interests: state.discoveryInterests ?? [], basis: moment.label + " · Moods made on this device", indexed: records.count, updated: records.map(\.fetched).max())
    }
}
