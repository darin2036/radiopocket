import Foundation
import CommonCrypto

/// Where radio bytes come from. Every source reports through the same four callbacks and exposes
/// `lastActivity` so the engine can notice a connection that silently stopped delivering audio.
protocol StreamSource: AnyObject {
    var lastActivity: Date { get }
    func stop()
}

/// A plain HTTP(S) stream with optional Shoutcast/Icecast ICY metadata interleaving.
final class HTTPSource: NSObject, URLSessionDataDelegate, StreamSource, @unchecked Sendable {
    var onResponse: ((String) -> Void)?     // lower-cased Content-Type
    var onData: ((Data) -> Void)?
    var onTitle: ((String) -> Void)?
    var onFailure: ((String) -> Void)?
    private(set) var lastActivity = Date()
    private let url: URL
    private let queue = OperationQueue()
    private var session: URLSession?
    private var stopped = false
    private var interval = 0, audioRemaining = 0, metadataRemaining = 0
    private var expectsLength = false
    private var metadataBytes = Data()

    init(url: URL) {
        self.url = url
        super.init()
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
    }

    func start() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 25
        config.urlCache = nil
        session = URLSession(configuration: config, delegate: self, delegateQueue: queue)
        var request = URLRequest(url: url)
        request.setValue("1", forHTTPHeaderField: "Icy-MetaData")
        request.setValue("RadioPocket/0.8", forHTTPHeaderField: "User-Agent")
        session?.dataTask(with: request).resume()
    }
    func stop() { stopped = true; session?.invalidateAndCancel(); session = nil }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            completionHandler(.cancel); if !stopped { stopped = true; onFailure?("The radio server returned an error.") }; return
        }
        interval = Int(http.value(forHTTPHeaderField: "icy-metaint") ?? "0") ?? 0
        interval = (0...16_777_216).contains(interval) ? interval : 0
        audioRemaining = interval
        lastActivity = Date()
        onResponse?((http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased())
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !stopped else { return }
        lastActivity = Date()
        if interval == 0 { if !data.isEmpty { onData?(data) }; return }
        var offset = 0
        while offset < data.count, !stopped {
            if expectsLength {
                metadataRemaining = Int(data[offset]) * 16; offset += 1; expectsLength = false; metadataBytes.removeAll(keepingCapacity: true)
                if metadataRemaining == 0 { audioRemaining = interval }
            } else if metadataRemaining > 0 {
                let count = min(metadataRemaining, data.count - offset)
                metadataBytes.append(data[offset..<offset + count]); offset += count; metadataRemaining -= count
                if metadataRemaining == 0 {
                    audioRemaining = interval
                    let text = String(data: metadataBytes, encoding: .utf8) ?? String(data: metadataBytes, encoding: .isoLatin1) ?? ""
                    if let start = text.range(of: "StreamTitle='"), let end = text.range(of: "';", range: start.upperBound..<text.endIndex) {
                        let title = String(text[start.upperBound..<end.lowerBound].prefix(512))
                        if !title.isEmpty { onTitle?(title) }
                    }
                }
            } else {
                let count = min(audioRemaining, data.count - offset)
                onData?(data.subdata(in: offset..<offset + count)); offset += count; audioRemaining -= count
                if audioRemaining == 0 { expectsLength = true }
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard !stopped else { return }
        stopped = true
        onFailure?(error?.localizedDescription ?? "The station closed the connection.")
    }
}

/// A small HLS client for audio streams: follows master playlists, polls live playlists, decrypts AES-128,
/// unwraps MPEG-TS / packed-audio segments into a continuous AAC or MP3 byte stream.
/// Fragmented MP4 and SAMPLE-AES streams report `unsupported` so the engine can fall back to AVPlayer.
final class HLSSource: StreamSource, @unchecked Sendable {
    static let unsupportedPrefix = "HLS-UNSUPPORTED:"
    var onAudio: ((Data) -> Void)?
    var onTitle: ((String) -> Void)?
    var onFailure: ((String) -> Void)?
    private(set) var lastActivity = Date()
    private let url: URL
    private var task: Task<Void, Never>?
    private let session: URLSession
    private var keys: [URL: Data] = [:]

    init(url: URL) {
        self.url = url
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.urlCache = nil
        config.httpAdditionalHeaders = ["User-Agent": "RadioPocket/0.8"]
        session = URLSession(configuration: config)
    }

    func start() {
        task = Task { [weak self] in
            do { try await self?.run() }
            catch is CancellationError {}
            catch { if !Task.isCancelled { self?.onFailure?((error as? RadioError)?.errorDescription ?? error.localizedDescription) } }
        }
    }
    func stop() { task?.cancel(); task = nil; session.invalidateAndCancel() }

    private func fetch(_ url: URL, limit: Int, attempts: Int = 3) async throws -> Data {
        var lastError: Error = RadioError.message("The HLS server did not respond.")
        for attempt in 0..<attempts {
            try Task.checkCancellation()
            do {
                let (data, response) = try await session.data(from: url)
                guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { throw RadioError.message("The HLS server returned an error.") }
                guard data.count <= limit else { throw RadioError.message("An HLS file exceeded its size limit.") }
                lastActivity = Date()
                return data
            } catch { try Task.checkCancellation(); lastError = error }
            if attempt < attempts - 1 { try await Task.sleep(nanoseconds: UInt64(1_000_000_000) << UInt64(attempt)) }
        }
        throw lastError
    }
    private func playlist(_ url: URL) async throws -> (HLSPlaylist, URL) {
        let data = try await fetch(url, limit: 1_048_576)
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { throw RadioError.message("The HLS playlist couldn’t be read.") }
        return (try HLSPlaylist.parse(text, base: url), url)
    }

    private func run() async throws {
        var (current, location) = try await playlist(url)
        if case .master(let variants) = current {
            location = HLSPlaylist.choose(variants).url
            current = try await playlist(location).0
        }
        guard case .media(var media) = current else { throw RadioError.message("This HLS stream has no media playlist.") }
        var next: Int?
        var failures = 0
        while true {
            try Task.checkCancellation()
            if let reason = media.unsupported { throw RadioError.message(Self.unsupportedPrefix + reason) }
            guard !media.segments.isEmpty else { throw RadioError.message("This HLS playlist has no segments.") }
            if next == nil { next = media.ended ? media.segments[0].sequence : media.segments[max(0, media.segments.count - 2)].sequence }
            if let first = media.segments.first?.sequence, next! < first { next = first }
            var fetched = false
            for segment in media.segments where segment.sequence >= next! {
                try Task.checkCancellation()
                try await deliver(segment)
                next = segment.sequence + 1; fetched = true
            }
            if media.ended { throw RadioError.message("The station closed the connection.") }
            try await Task.sleep(nanoseconds: UInt64((fetched ? 0.5 : max(0.5, media.targetDuration / 2)) * 1_000_000_000))
            do { media = try await reload(location); failures = 0 }
            catch is CancellationError { throw CancellationError() }
            catch { failures += 1; if failures >= 4 { throw error } }
        }
    }
    private func reload(_ location: URL) async throws -> HLSPlaylist.Media {
        guard case .media(let media) = try await playlist(location).0 else { throw RadioError.message("The HLS media playlist changed shape.") }
        return media
    }

    private func deliver(_ segment: HLSPlaylist.Segment) async throws {
        var data = try await fetch(segment.url, limit: 8_388_608)
        if let key = segment.key {
            let material: Data
            if let cached = keys[key.url] { material = cached } else { material = try await fetch(key.url, limit: 4096); keys[key.url] = material }
            guard material.count == 16, let clear = Self.decrypt(data, key: material, iv: HLSPlaylist.iv(for: segment)) else { throw RadioError.message("An encrypted HLS segment couldn’t be decrypted.") }
            data = clear
        }
        var title: String?
        switch TSDemuxer.kind(of: data) {
        case .transport:
            guard let result = TSDemuxer.audio(from: data) else { throw RadioError.message(Self.unsupportedPrefix + "This HLS stream has no AAC or MP3 audio in its transport stream.") }
            data = result.audio; title = result.title
        case .packedAudio:
            let stripped = TSDemuxer.stripID3(data); data = stripped.audio; title = stripped.title
        case .fragmentedMP4: throw RadioError.message(Self.unsupportedPrefix + "This HLS stream uses fragmented MP4 segments.")
        case .unknown: throw RadioError.message(Self.unsupportedPrefix + "This HLS stream uses an unrecognized segment format.")
        }
        if let title { onTitle?(title) }
        onAudio?(data)
    }

    static func decrypt(_ data: Data, key: Data, iv: Data) -> Data? {
        guard data.count % 16 == 0, !data.isEmpty else { return nil }
        var out = Data(count: data.count + 16)
        var produced = 0
        let status = out.withUnsafeMutableBytes { outBytes in
            data.withUnsafeBytes { input in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES128), CCOptions(kCCOptionPKCS7Padding),
                                keyBytes.baseAddress, 16, ivBytes.baseAddress, input.baseAddress, data.count, outBytes.baseAddress, outBytes.count, &produced)
                    }
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        return out.prefix(produced)
    }
}
