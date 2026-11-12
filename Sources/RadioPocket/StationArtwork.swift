import AppKit
import ImageIO
import Darwin

/// URLs come only from station metadata. Image bytes/decoded thumbnails live in RAM only.
/// Never uses a download task, URLCache, cookies, website scraping or a third-party image proxy.
enum StationArtwork {
    static let maximumBytes = 1_048_576
    private actor Gate {
        var active = 0
        var waiting: [CheckedContinuation<Void, Never>] = []
        func acquire() async {
            if active < 2 { active += 1; return }
            await withCheckedContinuation { waiting.append($0) }
        }
        func release() { if waiting.isEmpty { active -= 1 } else { waiting.removeFirst().resume() } }
    }
    private static let gate = Gate()
    private static let images: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>(); cache.countLimit = 16; cache.totalCostLimit = 4 * 1_048_576; return cache
    }()
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil; config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpCookieStorage = nil; config.httpShouldSetCookies = false; config.urlCredentialStorage = nil
        config.timeoutIntervalForRequest = 5; config.timeoutIntervalForResource = 8
        config.httpMaximumConnectionsPerHost = 2
        return URLSession(configuration: config)
    }()
    static func publicURL(_ text: String?) -> URL? {
        guard let text, text.count <= 2000, let url = try? StreamAddress.parse(text), url.user == nil, url.password == nil,
              let host = url.host?.lowercased(), host.contains("."), !host.contains(":"),
              !["localhost", "local", "internal", "test", "invalid"].contains(where: { host == $0 || host.hasSuffix("." + $0) }),
              url.port == nil || url.port == 80 || url.port == 443 else { return nil }
        if host.split(separator: ".").allSatisfy({ Int($0) != nil }) { return nil }
        return url
    }
    static func website(_ text: String) -> URL? {
        guard let url = try? StreamAddress.parse(text), url.user == nil, url.password == nil else { return nil }
        return url
    }
    private static func resolvesPublicly(_ host: String) -> Bool {
        var hints = addrinfo(); hints.ai_family = AF_UNSPEC; hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else { return false }
        defer { freeaddrinfo(first) }
        var node: UnsafeMutablePointer<addrinfo>? = first
        while let current = node {
            guard let address = current.pointee.ai_addr else { return false }
            if current.pointee.ai_family == AF_INET6 {
                let addr = UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_in6.self).pointee.sin6_addr
                let isGlobal = withUnsafeBytes(of: addr) { ($0[0] & 0xe0) == 0x20 }
                guard isGlobal else { return false }
                node = current.pointee.ai_next; continue
            }
            guard current.pointee.ai_family == AF_INET else { return false }
            let ipv4 = UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr.s_addr.bigEndian
            let a = (ipv4 >> 24) & 255, b = (ipv4 >> 16) & 255
            if a == 0 || a == 10 || a == 127 || a >= 224 || (a == 169 && b == 254) || (a == 172 && (16...31).contains(b)) || (a == 192 && b == 168) || (a == 100 && (64...127).contains(b)) || (a == 198 && (18...19).contains(b)) { return false }
            node = current.pointee.ai_next
        }
        return true
    }
    private final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    }
    private static let noRedirects = NoRedirects()
    static func image(at text: String?) async -> NSImage? {
        guard let url = publicURL(text) else { return nil }
        let key = url.absoluteString as NSString
        if let image = images.object(forKey: key) { return image }
        await gate.acquire()
        defer { Task { await gate.release() } }
        guard !Task.isCancelled else { return nil }
        if let image = images.object(forKey: key) { return image }
        let publicHost = await Task.detached(priority: .utility) { resolvesPublicly(url.host ?? "") }.value
        guard publicHost, !Task.isCancelled else { return nil }
        do {
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 5)
            request.setValue("image/png,image/jpeg,image/webp,image/gif,image/x-icon", forHTTPHeaderField: "Accept")
            let (bytes, response) = try await session.bytes(for: request, delegate: noRedirects)
            defer { bytes.task.cancel() }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  response.expectedContentLength <= maximumBytes,
                  response.mimeType?.hasPrefix("image/") == true, response.mimeType != "image/svg+xml" else { return nil }
            var data = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                guard data.count < maximumBytes else { return nil }
                data.append(byte)
            }
            guard let image = thumbnail(data) else { return nil }
            images.setObject(image, forKey: key, cost: 256 * 256 * 4)
            return image
        } catch { return nil }
    }
    static func thumbnail(_ data: Data) -> NSImage? {
        guard data.count <= maximumBytes, let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 4096, height <= 4096,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 256, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }
    static func clearMemory() { images.removeAllObjects() }
}
