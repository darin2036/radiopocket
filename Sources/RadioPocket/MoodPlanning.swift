import Foundation

/// A model plans listening activities and genre-backed collections; only the local selector resolves stations.
struct MoodPlan: Codable, Equatable {
    struct Collection: Codable, Equatable { var title: String; var genres: [String] }
    struct Activity: Codable, Equatable {
        var title: String
        var detail: String
        var artwork: String
        var collections: [Collection]
    }
    var activities: [Activity]
    var greetings: [String] = []
    static let artwork = ["sun", "sunrise", "moon", "rain", "snow", "cloud", "focus", "party", "dinner"]
    func validated(available: Set<String>) throws -> MoodPlan {
        func text(_ value: String, limit: Int) -> Bool {
            !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.count <= limit &&
            !value.contains("://") && !value.contains("\n") && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
        }
        guard (1...4).contains(activities.count), Set(activities.map { $0.title.lowercased() }).count == activities.count,
              activities.allSatisfy({ activity in
                  text(activity.title, limit: 45) && text(activity.detail, limit: 120) && Self.artwork.contains(activity.artwork) &&
                  (1...3).contains(activity.collections.count) && Set(activity.collections.map { $0.title.lowercased() }).count == activity.collections.count &&
                  activity.collections.allSatisfy { text($0.title, limit: 45) && (1...5).contains($0.genres.count) && Set($0.genres).isSubset(of: available) }
              }) else { throw RadioError.message("The mood plan could not be matched to your directories") }
        return self
    }
}
struct MoodGroup {
    var title: String
    var detail: String
    var artwork: String
    var collections: [DiscoveryShelf]
}

enum MoodPlanning {
    struct Context {
        var moment: MoodCuration.Moment
        var weather: MoodWeather.Kind?
        var genreCounts: [String: Int]
        var preferences: [String]
        var languages: [String]
        var sources: [String]
        var prompt: String {
            // Canonical ordering and day/period buckets deliberately omit minutes, request timestamps and station text.
            ["Plan version: 4", "Local day: \(moment.day); \(moment.label); weekend: \(moment.weekend)",
             "Calendar occasion: " + (moment.occasion ?? "none supplied"),
             "Current weather: " + (weather?.rawValue ?? "unknown; do not infer weather"),
             "Available genres (eligible station counts): " + genreCounts.keys.sorted().map { $0 + ":\(genreCounts[$0]!)" }.joined(separator: ", "),
             "Taste signals: " + preferences.joined(separator: ", "),
             "Preferred broadcast languages: " + languages.sorted().joined(separator: ", ")].joined(separator: "\n")
        }
        var cacheKey: String { prompt + "\nSources: " + sources.sorted().joined(separator: ",") }
    }
    static func context(records: [DiscoveryIndex.Record], state: Library.State, moment: MoodCuration.Moment, weather: MoodWeather.Kind?) -> Context {
        let groups = Dictionary(grouping: records, by: { DiscoveryIndex.matchKey($0.restored.address) })
        var counts: [String: Int] = [:]
        var eligible: [String: RadioListing] = [:]
        for (key, group) in groups {
            if Task.isCancelled { break }
            guard group.allSatisfy({ DiscoverySafety.allows($0.restored) }), let row = group.max(by: { $0.fetched < $1.fetched })?.restored,
                  !row.video, row.quality >= DiscoveryRecommendations.minimumQuality,
                  DiscoveryFeedback.vote(for: row, in: state.discoveryFeedback ?? [:], legacy: Set(state.discoveryDismissed ?? [])) >= 0 else { continue }
            let languages = Set(group.flatMap { $0.restored.languages ?? [] })
            if let preferred = state.discoveryLanguages, !preferred.isEmpty {
                if languages.isEmpty { guard state.discoveryIncludeUnknownLanguage != false else { continue } }
                else if languages.isDisjoint(with: Set(preferred)) { continue }
            }
            eligible[key] = row
            for genre in DiscoverySafety.interests(row).subtracting(["music"]) { counts[genre, default: 0] += 1 }
        }
        var preferenceScores: [String: Int] = [:]
        for genre in state.discoveryInterests ?? [] where DiscoveryCatalog.genres.contains(genre) { preferenceScores[genre, default: 0] += 20 }
        let stations = state.favorites + (state.discoveryPersonalization != false ? Array((state.recentStations ?? []).prefix(20)) : [])
        for station in stations {
            guard let row = eligible[DiscoveryIndex.matchKey(station.address)] else { continue }
            for genre in DiscoverySafety.interests(row) { preferenceScores[genre, default: 0] += 1 }
        }
        let preferences = preferenceScores.keys.sorted { preferenceScores[$0] == preferenceScores[$1] ? $0 < $1 : preferenceScores[$0]! > preferenceScores[$1]! }
        return Context(moment: moment, weather: weather, genreCounts: counts, preferences: Array(preferences.prefix(12)), languages: state.discoveryLanguages ?? [], sources: Array(Set(records.map(\.sourceID))))
    }
    static func validate(_ plan: MoodPlan, context: Context) throws -> MoodPlan {
        let bounded = try plan.validated(available: Set(context.genreCounts.keys))
        let activities = bounded.activities.filter { activity in
            let title = activity.title.lowercased(), text = (activity.title + " " + activity.detail).lowercased()
            if !context.moment.weekend && text.contains("weekend") { return false }
            let weekdays = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
            for (index, day) in weekdays.enumerated() where text.contains(day) && context.moment.weekday != index + 1 { return false }
            for period in ["morning", "afternoon", "evening"] where title.contains(period) && context.moment.period.lowercased() != period { return false }
            if title.contains("late-night") && context.moment.period != "Late night" { return false }
            let knownOccasions = ["new year's", "valentine", "halloween", "christmas"]
            for occasion in knownOccasions where text.contains(occasion) && !(context.moment.occasion?.lowercased().contains(occasion) ?? false) { return false }
            if activity.artwork == "rain" && context.weather != .rain { return false }
            if activity.artwork == "snow" && context.weather != .snow { return false }
            if activity.artwork == "cloud" && (context.weather == nil || context.weather == .clear) { return false }
            return true
        }
        guard !activities.isEmpty else { throw RadioError.message("The suggested moods did not fit this moment") }
        let greetings = bounded.greetings.prefix(8).filter { greeting in
            let text = greeting.lowercased()
            guard !greeting.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  greeting.count <= 60, !greeting.contains("://"),
                  !greeting.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return false }
            for (index, day) in ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"].enumerated() where text.contains(day) && context.moment.weekday != index + 1 { return false }
            for period in ["morning", "afternoon", "evening"] where text.contains(period) && context.moment.period.lowercased() != period { return false }
            if text.contains("weekend") && !context.moment.weekend { return false }
            if text.contains("rain") && context.weather != .rain { return false }
            if text.contains("snow") && context.weather != .snow { return false }
            for holiday in ["christmas", "halloween", "valentine", "new year's"] where text.contains(holiday) && !(context.moment.occasion?.lowercased().contains(holiday) ?? false) { return false }
            return true
        }
        return MoodPlan(activities: activities, greetings: Array(greetings))
    }
    static func fallback(_ context: Context) -> MoodPlan {
        let themes = MoodCuration.themes(for: context.moment, weather: context.weather)
        let activities = themes.compactMap { theme -> MoodPlan.Activity? in
            let genres = theme.genres.filter { context.genreCounts[$0] != nil }
            guard !genres.isEmpty else { return nil }
            let title: String
            if theme.title.contains("rainy") { title = "Rainy-day retreat" }
            else if theme.title.contains("energy") { title = "Party time" }
            else if theme.title.contains("day behind") || theme.title.contains("after hours") { title = "Happy hour" }
            else { title = theme.title }
            let collections = genres.prefix(3).map { MoodPlan.Collection(title: $0.capitalized + " for " + title.lowercased(), genres: [$0]) }
            return MoodPlan.Activity(title: title, detail: "A few listening directions for " + context.moment.label.lowercased() + ".", artwork: artwork(title: theme.title, moment: context.moment), collections: collections)
        }
        if !activities.isEmpty { return MoodPlan(activities: Array(activities.prefix(4))) }
        let genres = context.genreCounts.keys.sorted().prefix(3)
        return MoodPlan(activities: genres.isEmpty ? [] : [.init(title: "Explore the moment", detail: "Sounds available in your directories right now.", artwork: "sun", collections: genres.map { .init(title: $0.capitalized + " discoveries", genres: [$0]) })])
    }
    /// Stable within a local day and time-of-day bucket, including refreshes.
    static func greeting(moment: MoodCuration.Moment, name: String, options: [String]) -> String {
        var choices = options
        if choices.isEmpty {
            choices = [moment.greeting(name: name), "Your next good listen starts here", "What sounds good today?", "A little radio for your day"]
            switch moment.period {
            case "Morning": choices += ["Rise, shine, and tune in", "Coffee first. Good radio next.", "Morning has a soundtrack"]
            case "Afternoon": choices += ["An afternoon worth tuning into", "A little lift for your afternoon", "Let the afternoon play"]
            case "Evening": choices += ["Let the evening find its rhythm", "Good tunes. Evening sorted.", "Your evening, with a soundtrack"]
            default: choices += ["Still up? Tune in.", "A soundtrack for the quiet hours", "Let the night play on"]
            }
            if moment.weekday == 2 && moment.period == "Morning" { choices += ["Monday morning, amirite?"] }
            if moment.weekend { choices += ["Weekend mode: tuned in", "Less hurry. More radio."] }
        }
        let seed = moment.day + moment.period.utf8.reduce(0) { $0 + Int($1) }
        return choices[((seed % choices.count) + choices.count) % choices.count]
    }
    static func artwork(title: String, moment: MoodCuration.Moment) -> String {
        let value = title.lowercased()
        if value.contains("rain") { return "rain" }; if value.contains("snow") { return "snow" }; if value.contains("cloud") { return "cloud" }
        if value.contains("focus") { return "focus" }; if value.contains("energy") || value.contains("hours") { return "party" }; if value.contains("dinner") { return "dinner" }
        return moment.period == "Morning" ? "sunrise" : moment.period == "Afternoon" ? "sun" : "moon"
    }
    static func build(records: [DiscoveryIndex.Record], state: Library.State, context: Context, plan: MoodPlan, availability: [String: DiscoveryAvailability.Evidence] = [:]) -> DiscoveryFeed {
        var groups: [MoodGroup] = []
        for activity in plan.activities {
            if Task.isCancelled { break }
            // Resolve each mood independently: suitable stations may fit several moods.
            let themes = activity.collections.map { MoodCuration.Theme(title: $0.title, genres: $0.genres) }
            let feed = MoodCuration.build(records: records, state: state, moment: context.moment, themes: themes, availability: availability)
            // Round-robin the musical directions so the first collection cannot fill all four slots.
            var selected = feed.shelves.map { _ in [DiscoveryPick]() }
            var count = 0
            for offset in 0..<(feed.shelves.map { $0.picks.count }.max() ?? 0) {
                for index in feed.shelves.indices where count < 4 && offset < feed.shelves[index].picks.count {
                    selected[index].append(feed.shelves[index].picks[offset]); count += 1
                }
                if count == 4 { break }
            }
            let shelves = feed.shelves.enumerated().compactMap { index, shelf -> DiscoveryShelf? in
                guard !selected[index].isEmpty else { return nil }
                return DiscoveryShelf(title: shelf.title, subtitle: shelf.subtitle, picks: selected[index])
            }
            if !shelves.isEmpty { groups.append(.init(title: activity.title, detail: activity.detail, artwork: activity.artwork, collections: shelves)) }
        }
        return DiscoveryFeed(shelves: groups.flatMap(\.collections), interests: context.preferences, basis: context.moment.label + " · Moods made on this device", indexed: records.count, updated: records.map(\.fetched).max(), moodGroups: groups, moodGreetings: plan.greetings)
    }
}
