import Foundation

/// Type-ahead matching for Jump to Station: every typed word must appear in the station's name or address.
enum StationSearch {
    static func match(_ query: String, in stations: [Station]) -> [Station] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return stations }
        var ranked: [(rank: Int, index: Int, station: Station)] = []
        for (index, station) in stations.enumerated() {
            let name = station.name.lowercased(), address = station.address.lowercased()
            guard words.allSatisfy({ name.contains($0) || address.contains($0) }) else { continue }
            let starts = name.hasPrefix(words[0]) ? 0 : name.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).contains { $0.hasPrefix(words[0]) } ? 1 : 2
            ranked.append((starts, index, station))
        }
        return ranked.sorted { ($0.rank, $0.index) < ($1.rank, $1.index) }.map(\.station)
    }
}
