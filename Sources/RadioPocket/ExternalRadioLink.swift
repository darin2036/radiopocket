import Foundation

/// Handles explicit app links and downloaded playlists; never treats local media as radio.
enum ExternalRadioLink {
    static func station(for url: URL) throws -> Station {
        guard url.absoluteString.utf8.count <= 16_384 else { throw RadioError.message("This radio link is too long.") }
        if url.isFileURL { return try playlist(url) }
        if url.scheme?.lowercased() == "radiopocket" {
            guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  parts.host == "play", parts.path.isEmpty || parts.path == "/",
                  parts.user == nil, parts.password == nil, parts.port == nil, parts.fragment == nil,
                  let items = parts.queryItems,
                  items.filter({ $0.name == "url" }).count == 1,
                  let raw = items.first(where: { $0.name == "url" })?.value else {
                throw RadioError.message("Invalid RadioPocket link. Use radiopocket://play?url= followed by an encoded HTTP stream URL.")
            }
            let stream = try StreamAddress.parse(raw)
            let name = items.first(where: { $0.name == "name" })?.value ?? stream.host ?? "Internet Radio"
            return Station(name: cleanName(name), address: stream.absoluteString)
        }
        let stream = try StreamAddress.parse(url.absoluteString)
        return Station(name: stream.host ?? "Internet Radio", address: stream.absoluteString)
    }

    static func link(for station: Station) throws -> URL {
        let stream = try StreamAddress.parse(station.address)
        var parts = URLComponents()
        parts.scheme = "radiopocket"; parts.host = "play"
        parts.queryItems = [URLQueryItem(name: "url", value: stream.absoluteString), URLQueryItem(name: "name", value: cleanName(station.name))]
        guard let url = parts.url, url.absoluteString.utf8.count <= 16_384 else { throw RadioError.message("This radio link is too long to share.") }
        return url
    }

    private static func cleanName(_ name: String) -> String {
        let value = String(name.filter { !$0.isNewline && !$0.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) }.prefix(200))
        return value.isEmpty ? "Internet Radio" : value
    }

    private static func playlist(_ url: URL) throws -> Station {
        guard ["m3u", "m3u8", "pls"].contains(url.pathExtension.lowercased()) else {
            throw RadioError.message("Open a radio M3U, M3U8, or PLS playlist. Local music files aren’t supported.")
        }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let info = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard info.isRegularFile == true, (info.fileSize ?? Int.max) <= 262_144 else { throw RadioError.message("This playlist is too large (256 KB maximum).") }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let data = try file.read(upToCount: 262_145) ?? Data()
        guard data.count <= 262_144, let raw = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { throw RadioError.message("This playlist couldn’t be read.") }
        let text = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\u{FEFF}"))
        guard !text.components(separatedBy: .newlines).contains(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("#EXT-X-") }) else {
            throw RadioError.message("This is a downloaded HLS manifest. Open its original HTTPS URL instead, so relative audio segments can be resolved.")
        }
        let stream = try StreamAddress.playlistEntry(text, base: url)
        return Station(name: cleanName(url.deletingPathExtension().lastPathComponent), address: stream.absoluteString)
    }
}
