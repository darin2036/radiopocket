import Foundation
import Darwin
import Network

/// Local reachability evidence, deliberately independent of audio-quality stars.
final class DiscoveryAvailability: @unchecked Sendable {
    struct Evidence: Codable, Equatable {
        var checked: Date
        var verified: Date?
        var failures: Int
        var excludedUntil: Date?
        var label: String {
            if Date().timeIntervalSince(checked) > DiscoveryAvailability.verifiedFor { return "Availability check due" }
            if let verified, checked == verified { return "Stream responded recently" }
            return failures > 0 ? "Retrying availability" : "Availability unconfirmed"
        }
        func boost(at now: Date) -> Double {
            guard failures == 0, let verified else { return 0 }
            return min(8, max(0, 8 * (1 - now.timeIntervalSince(verified) / 3600)))
        }
        func excluded(at now: Date) -> Bool { excludedUntil.map { $0 > now } ?? false }
    }
    private static let registryLock = NSLock()
    private static var stores: [URL: DiscoveryAvailability] = [:]
    static func shared(directory: URL) -> DiscoveryAvailability {
        registryLock.withLock {
            if let store = stores[directory] { return store }
            let store = DiscoveryAvailability(file: directory.appendingPathComponent("discovery-availability.json"))
            stores[directory] = store; return store
        }
    }
    static let retryGap: TimeInterval = 120
    static let verifiedFor: TimeInterval = 900
    private let file: URL?
    private let lock = NSLock()
    private var values: [String: Evidence]
    init(file: URL?) {
        self.file = file
        if let file, let data = try? Data(contentsOf: file), data.count <= 2_000_000,
           let decoded = try? JSONDecoder().decode([String: Evidence].self, from: data) { values = decoded }
        else { values = [:] }
    }
    func snapshot(now: Date = Date()) -> [String: Evidence] {
        lock.withLock { values.filter { now.timeIntervalSince($0.value.checked) < 7 * 86400 } }
    }
    func due(_ address: String, now: Date = Date()) -> Bool {
        lock.withLock {
            guard let record = values[DiscoveryIndex.endpointKey(address)] else { return true }
            if record.excluded(at: now) { return false }
            return now.timeIntervalSince(record.checked) >= (record.failures == 0 && record.verified == record.checked ? Self.verifiedFor : Self.retryGap)
        }
    }
    func record(_ address: String, verdict: StreamVerdict, now: Date = Date()) {
        lock.withLock {
            let key = DiscoveryIndex.endpointKey(address), old = values[key]
            // Repeated renders/checks within the retry gap cannot create additional strikes.
            if verdict != .alive, let old, now.timeIntervalSince(old.checked) < Self.retryGap { return }
            switch verdict {
            case .alive: values[key] = Evidence(checked: now, verified: now, failures: 0, excludedUntil: nil)
            case .dead, .doubtful:
                let failures = min(3, (old.flatMap { now.timeIntervalSince($0.checked) < 3600 ? $0.failures : nil } ?? 0) + 1)
                values[key] = Evidence(checked: now, verified: old?.verified, failures: failures, excludedUntil: failures >= 3 ? now.addingTimeInterval(1800) : nil)
            case .unknown:
                // Offline, restricted, unsupported and cancelled checks are not station failures.
                values[key] = Evidence(checked: now, verified: old?.verified, failures: old?.failures ?? 0, excludedUntil: old?.excludedUntil)
            }
            values = values.filter { now.timeIntervalSince($0.value.checked) < 7 * 86400 }
            if values.count > 5000 { values = Dictionary(uniqueKeysWithValues: values.sorted { $0.value.checked > $1.value.checked }.prefix(5000).map { ($0.key, $0.value) }) }
            if let file, let data = try? JSONEncoder().encode(values) {
                try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: file, options: .atomic)
            }
        }
    }
    func recordPlayback(_ address: String, now: Date = Date()) {
        let needed = lock.withLock {
            guard let value = values[DiscoveryIndex.endpointKey(address)] else { return true }
            return value.failures > 0 || value.verified.map { now.timeIntervalSince($0) >= Self.verifiedFor } ?? true
        }
        if needed { record(address, verdict: .alive, now: now) }
    }
    func clear() { lock.withLock { values = [:]; if let file { try? FileManager.default.removeItem(at: file) } } }
}

/// Bounded GETs pinned to a validated public IPv4 destination. No cookies, credentials,
/// proxies, curl configuration, automatic redirects or downloaded media files.
enum DiscoveryProbe {
    struct Reply { var status: Int; var type: String; var location: String?; var body: Data }
    static func publicIPv4(_ text: String) -> Bool {
        let p = text.split(separator: ".").compactMap { Int($0) }
        guard p.count == 4, p.allSatisfy({ (0...255).contains($0) }) else { return false }
        let a = p[0], b = p[1]
        return !(a == 0 || a == 10 || a == 127 || a >= 224 || (a == 100 && (64...127).contains(b)) || (a == 169 && b == 254) || (a == 172 && (16...31).contains(b)) || (a == 192 && (b == 168 || b == 0 || b == 2)) || (a == 198 && (b == 18 || b == 19 || b == 51)) || (a == 203 && b == 0))
    }
    static func allowed(_ url: URL) -> Bool {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.user == nil, url.password == nil,
              url.absoluteString.count <= 4096, let host = url.host?.lowercased(), host.contains("."), !host.contains(":"),
              !["local", "localhost", "internal", "invalid", "test"].contains(where: { host == $0 || host.hasSuffix("." + $0) }) else { return false }
        if host.split(separator: ".").allSatisfy({ Int($0) != nil }) { return publicIPv4(host) }
        return true
    }
    static func destination(_ host: String) -> String? {
        var hints = addrinfo(); hints.ai_family = AF_INET; hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else { return nil }
        defer { freeaddrinfo(first) }
        var node: UnsafeMutablePointer<addrinfo>? = first, selected: String?
        while let current = node {
            guard let address = current.pointee.ai_addr else { return nil }
            var ip = UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &ip, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else { return nil }
            let text = String(cString: buffer)
            guard publicIPv4(text) else { return nil }
            selected = selected ?? text; node = current.pointee.ai_next
        }
        return selected
    }
    static func parse(_ data: Data) -> Reply? {
        guard let boundary = data.range(of: Data("\r\n\r\n".utf8)), boundary.lowerBound < 16384,
              let header = String(data: data[..<boundary.lowerBound], encoding: .utf8) else { return nil }
        let lines = header.components(separatedBy: "\r\n")
        guard let first = lines.first, first.hasPrefix("HTTP/"), let code = first.split(separator: " ").dropFirst().first.flatMap({ Int($0) }) else { return nil }
        var fields: [String: String] = [:]
        for line in lines.dropFirst() { if let split = line.firstIndex(of: ":") { fields[String(line[..<split]).lowercased()] = line[line.index(after: split)...].trimmingCharacters(in: .whitespaces) } }
        return Reply(status: code, type: fields["content-type"]?.lowercased() ?? "", location: fields["location"], body: Data(data[boundary.upperBound...]))
    }
    static func fetch(_ url: URL) -> Reply? {
        guard allowed(url), let host = url.host, let ip = destination(host) else { return nil }
        return transfer(url, pinnedIPv4: ip)
    }
    /// Separate transport seam allows loopback fixtures without relaxing production URL validation.
    static func transfer(_ url: URL, pinnedIPv4 ip: String) -> Reply? {
        #if os(macOS)
        guard let host = url.host else { return nil }
        let port = url.port ?? (url.scheme == "https" ? 443 : 80)
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        process.arguments = ["-q", "--silent", "--include", "--http1.1", "--noproxy", "*", "--proto", "=http,https", "--connect-timeout", "3", "--max-time", "6", "--resolve", "\(host):\(port):\(ip)", "--user-agent", "RadioPocket/0.9.1", "--header", "Icy-MetaData: 0", "--", url.absoluteString]
        process.standardOutput = output; process.standardError = FileHandle.nullDevice; process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        var data = Data()
        while data.count < 49152 {
            guard let chunk = try? output.fileHandleForReading.read(upToCount: min(4096, 49152 - data.count)), !chunk.isEmpty else { break }
            data.append(chunk)
            if let reply = parse(data), reply.body.count >= 32768 { break }
        }
        if process.isRunning { process.terminate() }
        process.waitUntilExit(); try? output.fileHandleForReading.close()
        return parse(data) ?? ([7, 28, 52, 56].contains(process.terminationStatus) ? Reply(status: 599, type: "", location: nil, body: Data()) : nil)
        #else
        return nil
        #endif
    }
    /// Redirects and playlist references go through the same pinned transport, with a strict hop budget.
    static func evaluate(_ url: URL, remaining: Int = 3, fetch: (URL) -> Reply?) -> StreamVerdict {
        guard remaining > 0, allowed(url), let response = fetch(url) else { return .unknown }
        if (300...399).contains(response.status) {
            guard let location = response.location, let next = URL(string: location, relativeTo: url)?.absoluteURL else { return .unknown }
            return evaluate(next, remaining: remaining - 1, fetch: fetch)
        }
        let verdict = StreamProbe.verdict(status: response.status, contentType: response.type)
        guard (200...299).contains(response.status) else { return verdict }
        if let text = String(data: response.body, encoding: .utf8), text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#EXTM3U") {
            let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            // Encrypted HLS and truncated/ambiguous manifests remain unconfirmed.
            guard !text.contains("#EXT-X-KEY"), let entry = lines.first(where: { !$0.isEmpty && !$0.hasPrefix("#") }),
                  let next = URL(string: entry, relativeTo: url)?.absoluteURL else { return .unknown }
            return evaluate(next, remaining: remaining - 1, fetch: fetch)
        }
        guard response.body.count >= 256 else { return .unknown }
        return verdict == .alive ? .alive : verdict == .dead ? .dead : .unknown
    }
    private static let network: NWPathMonitor = {
        let monitor = NWPathMonitor(); monitor.start(queue: DispatchQueue(label: "RadioPocket.availability.network")); return monitor
    }()
    static func check(_ address: String) async -> StreamVerdict {
        if network.currentPath.status != .satisfied { try? await Task.sleep(nanoseconds: 100_000_000) }
        guard network.currentPath.status == .satisfied, let url = URL(string: address), allowed(url), !Task.isCancelled else { return .unknown }
        let verdict = await Task.detached(priority: .utility) { evaluate(url, fetch: fetch) }.value
        return Task.isCancelled || network.currentPath.status != .satisfied ? .unknown : verdict
    }
}

/// One bounded batch at a time across refreshes/windows; no background catalog crawl.
actor DiscoveryAvailabilityChecks {
    static let shared = DiscoveryAvailabilityChecks()
    private var busy = false
    func refresh(_ rows: [RadioListing], store: DiscoveryAvailability) async -> Bool {
        guard !busy else { return false }
        busy = true; defer { busy = false }
        var seen = Set<String>()
        let due = Array(rows.filter { seen.insert(DiscoveryIndex.endpointKey($0.address)).inserted && store.due($0.address) }.prefix(6))
        guard !due.isEmpty else { return false }
        await withTaskGroup(of: Void.self) { group in
            var iterator = due.makeIterator()
            func next() {
                if let row = iterator.next() {
                    group.addTask {
                        let result = await DiscoveryProbe.check(row.address)
                        if !Task.isCancelled { store.record(row.address, verdict: result) }
                    }
                }
            }
            next(); next()
            while await group.next() != nil { if !Task.isCancelled { next() } }
        }
        return !Task.isCancelled
    }
}
