import Foundation

/// Winamp-style version history. The source is a plain text file: a `RadioPocket <version>`
/// header, an optional `Released: <date>` line, then one `* Kind: text` line per change.
struct Release: Equatable {
    let version: String
    let released: String?
    let entries: [String]
    var title: String { "RadioPocket \(version)" }
    /// Short label for pickers: "0.5 and earlier" becomes "0.5".
    var label: String { version.split(separator: " ").first.map(String.init) ?? version }
    /// Entries grouped by kind in standard changelog order, without the `* Kind:` prefix.
    var sections: [(kind: String, items: [String])] {
        Changelog.kinds.compactMap { kind in
            let prefix = "* \(kind): "
            let items = entries.filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
            return items.isEmpty ? nil : (kind, items)
        }
    }
    var text: String {
        let date = released.map { "  ·  \($0)" } ?? ""
        return ([title + date] + sections.map { "\n\($0.kind)\n" + $0.items.map { "  • " + $0 }.joined(separator: "\n") }).joined(separator: "\n")
    }
}

enum Changelog {
    static let header = "RadioPocket "
    /// Standard changelog order.
    static let kinds = ["Added", "Changed", "Removed", "Fixed"]

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
