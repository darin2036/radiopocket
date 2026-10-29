import Foundation

/// Winamp-style version history. The source is a plain text file: a `RadioPocket <version>`
/// header, an optional `Released: <date>` line, then one `* Kind: text` line per change.
struct Release: Equatable {
    let version: String
    let released: String?
    let entries: [String]
    var title: String { "RadioPocket \(version)" }
    var text: String { ([title] + entries).joined(separator: "\n") }
}

enum Changelog {
    static let header = "RadioPocket "

    static func parse(_ source: String) -> [Release] {
        var releases: [Release] = []
        var version: String?, released: String?, entries: [String] = []
        func flush() {
            if let version { releases.append(Release(version: version, released: released, entries: entries)) }
            version = nil; released = nil; entries = []
        }
        for raw in source.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix(header) { flush(); version = String(line.dropFirst(header.count)) }
            else if version != nil, line.lowercased().hasPrefix("released:") { released = line.dropFirst(9).trimmingCharacters(in: .whitespaces) }
            else if version != nil, line.hasPrefix("*") { entries.append(line) }
        }
        flush()
        return releases
    }

    static func load() -> [Release] {
        guard let url = Bundle.main.url(forResource: "CHANGELOG", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return parse(text)
    }
}
