import Foundation
import SQLite3

/// Owned exclusively by RadioDirectory's actor. Rebuildable metadata, never favorites or query history.
final class DiscoveryIndex {
    private var db: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    static let maximumRows = 100_000
    struct Record: Codable {
        private var value: StoredListing
        var listing: RadioListing { value.row }
        init(listing: RadioListing, sourceID: String, sourceName: String, video: Bool, directoryID: String?, fetched: Date) {
            value = StoredListing(listing); self.sourceID = sourceID; self.sourceName = sourceName; self.video = video; self.directoryID = directoryID; self.fetched = fetched
        }
        private struct StoredListing: Codable {
            var id: String, name: String, address: String, tags: String, country: String, countryCode: String, codec: String, homepage: String
            var bitrate: Int, votes: Int, clicks: Int
            var hls: Bool
            var artworkURL: String?
            var languages: [String]?
            init(_ row: RadioListing) {
                id = row.id; name = row.name; address = row.address; tags = row.tags; country = row.country; countryCode = row.countryCode; codec = row.codec; homepage = row.homepage
                bitrate = row.bitrate; votes = row.votes; clicks = row.clicks; hls = row.hls; artworkURL = row.artworkURL; languages = row.languages
            }
            var row: RadioListing {
                var row = RadioListing(id: id, name: name, address: address, tags: tags, country: country, countryCode: countryCode, codec: codec, bitrate: bitrate, votes: votes, clicks: clicks, hls: hls, sourceName: nil)
                row.homepage = homepage; row.artworkURL = artworkURL; row.languages = languages; return row
            }
        }
        var sourceID: String
        var sourceName: String
        var video: Bool
        var directoryID: String?
        var fetched: Date
        var restored: RadioListing {
            var row = listing; row.sourceName = sourceName; row.video = video; row.directoryID = directoryID
            return row
        }
    }
    init(url: URL?) throws {
        if let url { try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true) }
        guard sqlite3_open(url?.path ?? ":memory:", &db) == SQLITE_OK else { sqlite3_close(db); db = nil; throw RadioError.message("Couldn’t open the discovery index.") }
        do {
            try execute("PRAGMA journal_mode=DELETE; PRAGMA max_page_count=12288; PRAGMA busy_timeout=2000;")
            try execute("CREATE TABLE IF NOT EXISTS listings (source TEXT NOT NULL, native TEXT NOT NULL, endpoint TEXT NOT NULL, payload BLOB NOT NULL, fetched REAL NOT NULL, PRIMARY KEY(source,native)); CREATE INDEX IF NOT EXISTS endpoint_index ON listings(endpoint);")
            // Standalone FTS avoids depending on the serialized payload's shape.
            try execute("CREATE VIRTUAL TABLE IF NOT EXISTS terms USING fts5(name,tags,country); CREATE TABLE IF NOT EXISTS metadata (key TEXT PRIMARY KEY);")
        } catch { sqlite3_close(db); db = nil; throw error }
    }
    deinit { sqlite3_close(db) }
    private func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw RadioError.message("Discovery storage could not complete an update.") }
    }
    private func statement(_ sql: String) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { throw RadioError.message("Discovery search is unavailable.") }
        return stmt
    }
    private func bind(_ text: String, _ n: Int32, _ stmt: OpaquePointer) { sqlite3_bind_text(stmt, n, text, -1, transient) }
    static func endpointKey(_ address: String) -> String {
        guard var url = URLComponents(string: address) else { return address }
        url.scheme = url.scheme?.lowercased(); url.host = url.host?.lowercased()
        if (url.scheme == "https" && url.port == 443) || (url.scheme == "http" && url.port == 80) { url.port = nil }
        return url.string ?? address
    }
    func ingest(_ rows: [RadioListing], source: String, name: String, now: Date = Date()) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            for row in rows.prefix(5000) {
                guard (try? StreamAddress.parse(row.address)) != nil, row.name.count <= 1000, row.tags.count <= 4000 else { continue }
                let record = Record(listing: row, sourceID: source, sourceName: name, video: row.video, directoryID: row.directoryID, fetched: now)
                let payload = try JSONEncoder().encode(record)
                guard payload.count <= 16_384 else { continue }
                let old = try statement("SELECT rowid FROM listings WHERE source=? AND native=?")
                bind(source, 1, old); bind(row.id, 2, old)
                if sqlite3_step(old) == SQLITE_ROW { try execute("DELETE FROM terms WHERE rowid=\(sqlite3_column_int64(old, 0))") }
                sqlite3_finalize(old)
                let stmt = try statement("INSERT OR REPLACE INTO listings(source,native,endpoint,payload,fetched) VALUES(?,?,?,?,?)")
                bind(source, 1, stmt); bind(row.id, 2, stmt); bind(Self.endpointKey(row.address), 3, stmt)
                _ = payload.withUnsafeBytes { sqlite3_bind_blob(stmt, 4, $0.baseAddress, Int32(payload.count), transient) }
                sqlite3_bind_double(stmt, 5, now.timeIntervalSince1970)
                let result = sqlite3_step(stmt); sqlite3_finalize(stmt)
                guard result == SQLITE_DONE else { throw RadioError.message("Discovery index is full. Clear saved discovery data to rebuild it.") }
                let id = sqlite3_last_insert_rowid(db)
                let fts = try statement("INSERT INTO terms(rowid,name,tags,country) VALUES(?,?,?,?)")
                sqlite3_bind_int64(fts, 1, id); bind(row.name, 2, fts); bind(row.tags, 3, fts); bind(row.country + " " + row.countryCode, 4, fts)
                let inserted = sqlite3_step(fts); sqlite3_finalize(fts)
                guard inserted == SQLITE_DONE else { throw RadioError.message("Couldn’t index these listings.") }
            }
            try execute("DELETE FROM listings WHERE fetched < \(now.addingTimeInterval(-30 * 86400).timeIntervalSince1970); DELETE FROM listings WHERE rowid IN (SELECT rowid FROM listings ORDER BY fetched DESC LIMIT -1 OFFSET \(Self.maximumRows)); DELETE FROM terms WHERE rowid NOT IN (SELECT rowid FROM listings); COMMIT;")
        } catch { try? execute("ROLLBACK"); throw error }
    }
    func retainSources(_ sources: Set<String>) throws {
        let stmt = try statement("SELECT DISTINCT source FROM listings"); var obsolete: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let raw = sqlite3_column_text(stmt, 0) { let source = String(cString: raw); if !sources.contains(source) { obsolete.append(source) } }
        }
        sqlite3_finalize(stmt)
        for source in obsolete {
            let remove = try statement("DELETE FROM listings WHERE source=?"); bind(source, 1, remove); sqlite3_step(remove); sqlite3_finalize(remove)
        }
        try execute("DELETE FROM terms WHERE rowid NOT IN (SELECT rowid FROM listings)")
    }
    func records(text: String = "", sources: Set<String>, limit: Int = 5000) throws -> [Record] {
        guard !sources.isEmpty else { return [] }
        let words = StationSearch.words(String(text.prefix(500))).prefix(12)
        let match = words.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"*" }.joined(separator: " AND ")
        let sql = "SELECT payload FROM listings " + (match.isEmpty ? "" : "JOIN terms ON terms.rowid=listings.rowid ") + "WHERE source IN (" + Array(repeating: "?", count: sources.count).joined(separator: ",") + ") AND fetched >= ? " + (match.isEmpty ? "" : "AND terms MATCH ? ") + "ORDER BY " + (match.isEmpty ? "fetched DESC" : "bm25(terms)") + " LIMIT ?"
        let stmt = try statement(sql); defer { sqlite3_finalize(stmt) }
        var position: Int32 = 1
        for source in sources.sorted() { bind(source, position, stmt); position += 1 }
        sqlite3_bind_double(stmt, position, Date().addingTimeInterval(-30 * 86400).timeIntervalSince1970); position += 1
        if !match.isEmpty { bind(match, position, stmt); position += 1 }
        sqlite3_bind_int(stmt, position, Int32(min(100_000, max(1, limit))))
        var rows: [Record] = []
        var result = sqlite3_step(stmt)
        while result == SQLITE_ROW {
            defer { result = sqlite3_step(stmt) }
            guard let bytes = sqlite3_column_blob(stmt, 0) else { continue }
            let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(stmt, 0)))
            if let record = try? JSONDecoder().decode(Record.self, from: data), (try? StreamAddress.parse(record.restored.address)) != nil { rows.append(record) }
        }
        guard result == SQLITE_DONE else { throw RadioError.message("Saved discovery data could not be searched.") }
        return rows
    }
    func hasMigratedCache() throws -> Bool {
        let stmt = try statement("SELECT 1 FROM metadata WHERE key='legacy-cache'"); defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW
    }
    func markCacheMigrated() throws { try execute("INSERT OR IGNORE INTO metadata(key) VALUES('legacy-cache')") }
    func clear() throws { try execute("DELETE FROM listings; DELETE FROM terms; VACUUM;") }
}
