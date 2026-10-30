import Foundation

/// Type-ahead matching for Jump to Station: every typed word must appear in the station's name or address.
enum StationSearch {
    /// Case- and accent-insensitive words of a typed query, so "Café" finds "cafe" and word order never matters.
    static func words(_ query: String) -> [String] {
        fold(query).split(whereSeparator: \.isWhitespace).map(String.init)
    }
    static func fold(_ text: String) -> String { text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }
    /// True when every word appears somewhere in at least one of the fields (a substring match, not a whole-word one).
    static func matches(_ words: [String], in fields: [String]) -> Bool {
        let folded = fields.map(fold)
        return words.allSatisfy { word in folded.contains { $0.contains(word) } }
    }
    static func match(_ query: String, in stations: [Station]) -> [Station] {
        let words = words(query)
        guard !words.isEmpty else { return stations }
        var ranked: [(rank: Int, index: Int, station: Station)] = []
        for (index, station) in stations.enumerated() {
            guard matches(words, in: [station.name, station.address]) else { continue }
            let name = fold(station.name)
            let starts = name.hasPrefix(words[0]) ? 0 : name.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).contains { $0.hasPrefix(words[0]) } ? 1 : 2
            ranked.append((starts, index, station))
        }
        return ranked.sorted { ($0.rank, $0.index) < ($1.rank, $1.index) }.map(\.station)
    }
}
