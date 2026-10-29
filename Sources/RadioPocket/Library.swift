import Foundation

struct Station: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var name: String
    var address: String
}

enum RadioError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

enum StreamAddress {
    static func parse(_ text: String) throws -> URL {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains(where: { $0.isWhitespace }),
              let components = URLComponents(string: trimmed),
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              let host = components.host, !host.isEmpty,
              let url = components.url else {
            throw RadioError.message("Enter a full http:// or https:// stream URL. A station’s website usually isn’t its audio stream.")
        }
        return url
    }

    static func playlistEntry(_ text: String, base: URL) throws -> URL {
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        if lines.contains(where: { $0.hasPrefix("#EXT-X-") }) { return base }
        let candidates: [String]
        if lines.contains(where: { $0.lowercased() == "[playlist]" }) {
            candidates = lines.compactMap { line -> (Int, String)? in
                let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
                guard parts.count == 2, parts[0].lowercased().hasPrefix("file"),
                      let index = Int(parts[0].dropFirst(4)) else { return nil }
                return (index, parts[1].trimmingCharacters(in: .whitespaces))
            }.sorted { $0.0 < $1.0 }.map { $0.1 }
        } else {
            candidates = lines.filter { !$0.isEmpty && !$0.hasPrefix("#") }
        }
        for entry in candidates {
            if let absolute = URL(string: entry, relativeTo: base)?.absoluteURL,
               let valid = try? parse(absolute.absoluteString) { return valid }
        }
        throw RadioError.message("This playlist has no supported HTTP audio stream.")
    }

    static func resolve(_ url: URL, depth: Int = 0) async throws -> URL {
        guard ["m3u", "pls"].contains(url.pathExtension.lowercased()) else { return url }
        guard depth < 3 else { throw RadioError.message("Too many nested radio playlists.") }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("RadioPocket/0.1", forHTTPHeaderField: "User-Agent")
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw RadioError.message("The playlist server returned an error.")
        }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < 262_144 else { throw RadioError.message("This playlist is too large.") }
            data.append(byte)
        }
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw RadioError.message("The playlist couldn’t be read.")
        }
        let base = response.url ?? url
        let next = try playlistEntry(text, base: base)
        if next == base { return base }
        return try await resolve(next, depth: depth + 1)
    }
}

final class Library {
    struct State: Codable {
        var favorites: [Station] = []
        var lastStation: Station?
        var volume: Float = 0.65
        var alwaysOnTop: Bool?
        var scale: Double = 2
        var equalizer: EQSettings?
        var recentStations: [Station]?
        var visualizer: VisSettings?
        var directories: [DirectorySource]?
        var leveling: Bool?
    }
    let directory: URL
    private(set) var state: State
    var changed: (() -> Void)?

    init(directory: URL? = nil) throws {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("RadioPocket")
        try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
        let file = self.directory.appendingPathComponent("library.json")
        if FileManager.default.fileExists(atPath: file.path) {
            state = try JSONDecoder().decode(State.self, from: Data(contentsOf: file))
        } else { state = State() }
        state.volume = min(1, max(0, state.volume))
        if ![1.0, 2.0, 3.0].contains(state.scale) { state.scale = 2 }
    }

    func update(_ edit: (inout State) -> Void) throws {
        var next = state
        edit(&next)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(next).write(to: directory.appendingPathComponent("library.json"), options: .atomic)
        state = next
        changed?()
    }

    func recordRecent(_ station: Station) throws {
        try update { state in
            var entries = state.recentStations ?? []
            entries.removeAll { $0.address == station.address || $0.id == station.id }
            entries.insert(station, at: 0)
            state.recentStations = Array(entries.prefix(30))
        }
    }

    func save(_ station: Station) throws {
        _ = try StreamAddress.parse(station.address)
        try update { state in
            if let index = state.favorites.firstIndex(where: { $0.address == station.address || $0.id == station.id }) {
                state.favorites[index] = station
            } else { state.favorites.append(station) }
        }
    }
}
