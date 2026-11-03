import Foundation

struct Station: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var name: String
    var address: String
    /// True for an Internet TV channel; nil for radio, so saved stations from before TV support decode unchanged.
    var video: Bool?
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
        if text.range(of: "<asx", options: .caseInsensitive) != nil {
            candidates = capture("href\\s*=\\s*[\"']([^\"']+)[\"']", in: text)
        } else if text.range(of: "<location>", options: .caseInsensitive) != nil {
            candidates = capture("<location>\\s*([^<]+?)\\s*</location>", in: text)
        } else if lines.contains(where: { $0.lowercased() == "[playlist]" }) {
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

    private static func capture(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            Range(match.range(at: 1), in: text).map { String(text[$0]).replacingOccurrences(of: "&amp;", with: "&") }
        }
    }

    static func resolve(_ url: URL, depth: Int = 0) async throws -> URL {
        guard ["m3u", "pls", "asx", "xspf"].contains(url.pathExtension.lowercased()) else { return url }
        guard depth < 3 else { throw RadioError.message("Too many nested radio playlists.") }
        let agents = UserAgent.ladder(for: url.host)
        var fetched: (URLSession.AsyncBytes, URLResponse)?
        for (index, agent) in agents.enumerated() {
            var request = URLRequest(url: url, timeoutInterval: 15)
            if let agent { request.setValue(agent, forHTTPHeaderField: "User-Agent") }
            let attempt = try await URLSession.shared.bytes(for: request)
            if let http = attempt.1 as? HTTPURLResponse, (200...299).contains(http.statusCode) { fetched = attempt; break }
            if index == agents.count - 1 { break }
        }
        guard let (bytes, response) = fetched else { throw RadioError.message("The playlist server returned an error.") }
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

enum StereoBalance {
    /// Dragging within this distance of the middle settles on exact center balance.
    static let snap: Float = 0.2
    /// Clamps to -1…1 and settles on exact center near the middle, so dragging back is easy to land on.
    static func snapped(_ raw: Float) -> Float {
        let value = min(1, max(-1, raw))
        return abs(value) < snap ? 0 : value
    }
}

final class Library {
    struct State: Codable {
        var favorites: [Station] = []
        var lastStation: Station?
        var volume: Float = 0.65
        var balance: Float?
        var alwaysOnTop: Bool?
        var scale: Double = 2
        var equalizer: EQSettings?
        var spatial: SpatialSettings?
        var recentStations: [Station]?
        var visualizer: VisSettings?
        var directories: [DirectorySource]?
        /// Built-in skins the user has deleted, by their menu action.
        var hiddenSkins: [String]?
        var leveling: Bool?
        /// Keeps the opening station lists saved and fresh in the background. On unless turned off.
        var backgroundStations: Bool?
        /// Leaves out directory stations that no longer answer. On unless turned off.
        var checkStations: Bool?
        /// Internet TV filters: adult channels, and geo-blocked or unidentifiable streams. Both on unless turned off.
        var tvHideAdult: Bool?
        var tvHideUnreliable: Bool?
        var discoveryInterests: [String]?
        var discoveryDismissed: [String]?
        var discoveryFeedback: [String: Int]?
        var discoveryPersonalization: Bool?
        var discoveryAI: Bool?
        var moodCity: MoodCity?
        var moodWeatherPromptHandled: Bool?
        var discoveryLanguages: [String]?
        var discoveryIncludeUnknownLanguage: Bool?
        var discoveryAvailabilityChecks: Bool?
        var discoveryArtwork: Bool?
        var directoryClickReporting: Bool?
        /// Checks the source repository for a newer version at launch. On unless turned off.
        var checkForUpdates: Bool?
        var lastUpdateCheck: Date?
        /// Player text scroll speed in points per second; 0 turns automatic scrolling off. 30 unless changed.
        var textScrollSpeed: Double?
    }
    let directory: URL
    private(set) var state: State
    var changed: (() -> Void)?
    /// Fields in library.json that this version doesn't know about (written by a newer RadioPocket); kept and written back so nothing is lost.
    private var extras: [String: Any] = [:]
    /// The schema version recorded in the file we loaded; never lowered when saving.
    private var fileVersion = LibraryFormat.current

    var file: URL { directory.appendingPathComponent("library.json") }

    init(directory: URL? = nil) throws {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("RadioPocket")
        try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
        let file = self.directory.appendingPathComponent("library.json")
        var needsRewrite = false
        if FileManager.default.fileExists(atPath: file.path) {
            let loaded = try LibraryFormat.load(Data(contentsOf: file))
            state = loaded.state
            extras = loaded.extras
            fileVersion = loaded.version
            needsRewrite = loaded.savedVersion < LibraryFormat.current
            if loaded.savedVersion != LibraryFormat.current || !loaded.dropped.isEmpty {
                try LibraryFormat.backUp(file, in: self.directory, version: loaded.savedVersion)
            }
        } else { state = State() }
        state.volume = min(1, max(0, state.volume))
        state.balance = state.balance.map { min(1, max(-1, $0)) }
        if ![1.0, 1.5, 2.0, 3.0].contains(state.scale) { state.scale = 2 }
        if needsRewrite { try write(state) }
    }

    private func write(_ next: State) throws {
        fileVersion = max(fileVersion, LibraryFormat.current)
        try LibraryFormat.encode(next, extras: extras, version: fileVersion).write(to: file, options: .atomic)
    }

    func update(_ edit: (inout State) -> Void) throws {
        var next = state
        edit(&next)
        try write(next)
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

    func isFavorite(_ station: Station) -> Bool {
        state.favorites.contains { $0.address == station.address || $0.id == station.id }
    }

    func removeFavorite(_ station: Station) throws {
        try update { $0.favorites.removeAll { $0.address == station.address || $0.id == station.id } }
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

/// The on-disk format of library.json, built so saved data keeps working as the app grows.
///
/// Rules that keep old and new versions compatible:
/// - Add a field by giving `Library.State` a new optional property (or a non-optional one with a default). Files without it still load.
/// - Fields this version doesn't recognize are kept and written back, so an older build never erases a newer build's data.
/// - A field with an unusable value is dropped on its own; the rest of the file still loads, and the original is backed up.
/// - Rename, remove or reinterpret a field only with a numbered migration below, and raise `current`.
/// - Before a migration, or after dropping a bad field, the original file is copied to `Backups/`.
enum LibraryFormat {
    /// Bump when a migration is added. Version 0 is any file written before versioning existed.
    static let current = 1
    static let versionKey = "schemaVersion"
    static let backupLimit = 5

    typealias Migration = (inout [String: Any]) throws -> Void
    /// `migrations[n]` upgrades a version n file to version n + 1.
    static let migrations: [Int: Migration] = [
        0: { _ in }   // Versioning began; the layout itself did not change.
    ]

    struct Loaded {
        var state: Library.State
        var extras: [String: Any]
        var version: Int
        /// The version the file was saved with, before any migration.
        var savedVersion: Int
        /// Fields whose saved value couldn't be read and were reset.
        var dropped: [String]
    }

    private static let encoder: JSONEncoder = { let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]; return e }()

    /// Every field name `Library.State` writes, including optional ones that are currently unset.
    static var knownKeys: Set<String> { Set(Mirror(reflecting: Library.State()).children.compactMap(\.label)) }

    private static func object(_ state: Library.State) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: encoder.encode(state)) as? [String: Any] else { throw RadioError.message("The library couldn’t be encoded.") }
        return object
    }

    static func load(_ data: Data) throws -> Loaded {
        guard var raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RadioError.message("library.json isn’t a valid RadioPocket library.")
        }
        var version = (raw[versionKey] as? Int) ?? 0
        let savedVersion = version
        guard version >= 0 else { throw RadioError.message("library.json has an invalid version.") }
        while version < current {
            try migrations[version]?(&raw)
            version += 1
        }
        raw[versionKey] = nil
        let known = knownKeys
        let extras = raw.filter { !known.contains($0.key) }
        let defaults = try object(Library.State())
        var working = defaults.merging(raw.filter { known.contains($0.key) }) { _, saved in saved }
        var dropped: [String] = []
        for _ in 0...known.count {
            do {
                let state = try JSONDecoder().decode(Library.State.self, from: JSONSerialization.data(withJSONObject: working))
                return Loaded(state: state, extras: extras, version: version, savedVersion: savedVersion, dropped: dropped)
            } catch let error as DecodingError {
                guard let key = codingPath(of: error).first?.stringValue, working[key] != nil || defaults[key] != nil else { throw error }
                dropped.append(key)
                working[key] = defaults[key]
            }
        }
        throw RadioError.message("library.json couldn’t be read.")
    }

    private static func codingPath(of error: DecodingError) -> [CodingKey] {
        switch error {
        case .typeMismatch(_, let context), .valueNotFound(_, let context), .keyNotFound(_, let context), .dataCorrupted(let context): return context.codingPath
        @unknown default: return []
        }
    }

    static func encode(_ state: Library.State, extras: [String: Any], version: Int) throws -> Data {
        var out = extras
        for (key, value) in try object(state) { out[key] = value }
        out[versionKey] = version
        return try JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    /// Copies the file into `Backups/` and keeps only the newest few.
    static func backUp(_ file: URL, in directory: URL, version: Int) throws {
        let folder = directory.appendingPathComponent("Backups", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        try FileManager.default.copyItem(at: file, to: folder.appendingPathComponent("library-v\(version)-\(stamp).json"))
        let old = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("library-v") }.sorted { $0.lastPathComponent > $1.lastPathComponent }.dropFirst(backupLimit)
        for url in old { try? FileManager.default.removeItem(at: url) }
    }
}
