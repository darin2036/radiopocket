import Foundation

/// Discover is stricter than the general browser, even when its TV filters are disabled.
/// Metadata cannot certify the live broadcast; unknown categories are withheld from automatic recommendations.
enum DiscoverySafety {
    static let genres = ["ambient", "classical", "jazz", "electronic", "indie", "world", "blues", "folk", "soul", "rock", "pop", "reggae", "country", "instrumental", "chill", "lounge", "music"]
    private static let sensitive = try! NSRegularExpression(pattern: #"(?i)(?<![a-z])(adult\w*|explicit\w*|uncensored|nsfw|xxx|porn\w*|sex\w*|erotic\w*|hentai|fetish|bdsm|nude\w*|naked|18\+|violence|violent|gore|horror|suicide|self.harm|hate|extremis\w*|terror\w*|gambl\w*|casino|betting|drugs?|cannabis|marijuana|politic\w*|religio\w*|news|talk)(?![a-z])"#)
    static func tokens(_ text: String) -> Set<String> {
        Set(StationSearch.fold(text).components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty })
    }
    static func interests(_ listing: RadioListing) -> Set<String> {
        tokens(listing.tags + " " + listing.name).intersection(Set(genres))
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
}

enum DiscoveryRecommendations {
    static func build(records: [DiscoveryIndex.Record], recent: [Station], favorites: [Station], interests: [String], dismissed: Set<String>, personalizes: Bool, video: Bool, day: Int = Int(Date().timeIntervalSince1970 / 86400)) -> DiscoveryFeed {
        let grouped = Dictionary(grouping: records, by: { DiscoveryIndex.endpointKey($0.restored.address) })
        // Any conflicting sensitive metadata excludes the endpoint, not just the winning listing.
        let safe = grouped.values.filter { $0.allSatisfy { DiscoverySafety.allows($0.restored) } }
        let known = Dictionary(uniqueKeysWithValues: safe.compactMap { group -> (String, RadioListing)? in
            guard let first = group.first else { return nil }; return (DiscoveryIndex.endpointKey(first.restored.address), first.restored)
        })
        var affinity: [String: Double] = [:]
        let explicit = interests.filter { DiscoverySafety.genres.contains($0) }
        for genre in explicit { affinity[genre, default: 0] += 12 }
        var historyMatches = 0
        if personalizes {
            for (position, station) in recent.prefix(30).enumerated() {
                let row = known[DiscoveryIndex.endpointKey(station.address)] ?? RadioListing(station: station)
                guard DiscoverySafety.allows(row) else { continue }
                let tags = DiscoverySafety.interests(row)
                if !tags.isEmpty { historyMatches += 1 }
                for tag in tags { affinity[tag, default: 0] += max(1, 4 - Double(position) / 10) }
            }
        }
        for station in favorites {
            let row = known[DiscoveryIndex.endpointKey(station.address)] ?? RadioListing(station: station)
            if DiscoverySafety.allows(row) { for tag in DiscoverySafety.interests(row) { affinity[tag, default: 0] += 3 } }
        }
        let basis = !explicit.isEmpty ? "Shaped by your chosen interests" : historyMatches >= 3 ? "Inspired by your recent listening" : !affinity.isEmpty ? "A starting mix from your favorites and recent stations" : "A varied starting mix — no listening history needed"
        if affinity.isEmpty { for tag in ["ambient", "jazz", "classical", "world", "indie", "electronic"] { affinity[tag] = 1 } }
        let top = affinity.keys.sorted { affinity[$0] == affinity[$1] ? $0 < $1 : affinity[$0]! > affinity[$1]! }
        let heard = Set((personalizes ? recent : []).map { DiscoveryIndex.endpointKey($0.address) })
        let saved = Set(favorites.map { DiscoveryIndex.endpointKey($0.address) })
        let candidates: [DiscoveryPick] = safe.compactMap { group in
            guard let entry = group.sorted(by: { $0.fetched > $1.fetched }).first else { return nil }
            let row = entry.restored
            guard row.video == video, !dismissed.contains(DiscoveryIndex.endpointKey(row.address)) else { return nil }
            let match = top.first { DiscoverySafety.interests(row).contains($0) }
            return DiscoveryPick(listing: row, reason: match.map { "A little more " + $0 } ?? "A different corner of the dial", sources: Array(Set(group.map(\.sourceName))).sorted(), fetched: entry.fetched)
        }
        func score(_ pick: DiscoveryPick) -> Double {
            let row = pick.listing
            return DiscoverySafety.interests(row).reduce(0) { $0 + (affinity[$1] ?? 0) } + Double(row.quality) * 0.15 + Double(rotation(row.address, day: day) % 1000) / 1000
        }
        let ordered = candidates.sorted { let a = score($0), b = score($1); return a == b ? $0.listing.address < $1.listing.address : a > b }
        var used = Set<String>()
        func shelf(_ title: String, _ subtitle: String, _ pool: [DiscoveryPick]) -> DiscoveryShelf? {
            var hosts: [String: Int] = [:], picks: [DiscoveryPick] = []
            for pick in pool {
                let key = DiscoveryIndex.endpointKey(pick.listing.address), host = URL(string: key)?.host ?? key
                guard !used.contains(key), hosts[host, default: 0] < 2 else { continue }
                used.insert(key); hosts[host, default: 0] += 1; picks.append(pick)
                if picks.count == 6 { break }
            }
            return picks.isEmpty ? nil : DiscoveryShelf(title: title, subtitle: subtitle, picks: picks)
        }
        var shelves: [DiscoveryShelf] = []
        if let section = shelf("Your next frequency", basis, ordered.filter { !heard.contains(DiscoveryIndex.endpointKey($0.listing.address)) && !saved.contains(DiscoveryIndex.endpointKey($0.listing.address)) }) { shelves.append(section) }
        let unexpected = candidates.sorted { rotation($0.listing.address, day: day) < rotation($1.listing.address, day: day) }
        if let section = shelf("Beyond your usual", "Different sounds, refreshed each day on this device", unexpected.filter { DiscoverySafety.interests($0.listing).isDisjoint(with: Set(top.prefix(2))) }) { shelves.append(section) }
        if let section = shelf("Worth another listen", "Familiar stations from your local library", ordered.filter { heard.contains(DiscoveryIndex.endpointKey($0.listing.address)) || saved.contains(DiscoveryIndex.endpointKey($0.listing.address)) }) { shelves.append(section) }
        if let section = shelf("Around the dial", "More from your enabled directories", unexpected) { shelves.append(section) }
        return DiscoveryFeed(shelves: shelves, interests: Array(top.prefix(5)), basis: basis, indexed: records.count, updated: records.map(\.fetched).max())
    }
    private static func rotation(_ text: String, day: Int) -> UInt64 {
        (text + "|\(day)").utf8.reduce(UInt64(14695981039346656037)) { ($0 ^ UInt64($1)) &* 1099511628211 }
    }
}
