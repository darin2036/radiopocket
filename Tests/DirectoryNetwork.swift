import Foundation

@main struct DirectoryNetworkChecks {
    static func main() async {
        var count = 0
        func check(_ passed: Bool, _ label: String) throws {
            guard passed else { throw RadioError.message("FAIL: \(label)") }
            count += 1; print("PASS: \(label)")
        }
        do {
            guard CommandLine.arguments.count > 1, let base = URL(string: CommandLine.arguments[1]) else { throw RadioError.message("Pass the local mock directory base URL.") }
            let client = RadioDirectory(baseURLs: [URL(string: "http://127.0.0.1:1")!, base])
            var query = DirectoryQuery(); query.name = "network"
            let first = try await client.search(query)
            try check(first.stations.count == 100 && first.hasMore, "Directory fails over from an unavailable mirror")
            let moved = await client.refreshed(uuid: "00000000-0000-0000-0000-00000000004d")
            try check(moved?.address.hasSuffix("moved=1") == true, "A saved station’s current address is looked up by its directory UUID")
            let unknown = await client.refreshed(uuid: "00000000-0000-0000-0000-000000000063")
            let notUUID = await client.refreshed(uuid: "not-a-uuid")
            try check(unknown == nil && notUUID == nil, "Unknown or non-directory station IDs refresh to nothing")
            let failing = Station(name: "Jazz FM Deluxe Live", address: "http://127.0.0.1:1/dead")
            let alternates = await client.alternates(for: failing)
            try check(!alternates.isEmpty && alternates.allSatisfy { $0.address != failing.address } && alternates.count <= 3, "Alternates are searched by the station name and exclude the failing address")
            try check(try await client.search(query).cached, "Repeat searches use the small memory cache")
            try check(!(try await client.search(query, refresh: true)).cached, "Refresh bypasses cached results")
            var page2 = query; page2.offset = 100
            let second = try await client.search(page2)
            try check(second.stations.count == 3 && !second.hasMore && second.stations.first?.name == "network Radio 101", "Next page uses its server offset")
            var empty = query; empty.name = "empty"
            try check(try await client.search(empty).stations.isEmpty, "Empty search returns an empty page")
            for name in ["failure", "badjson", "oversize"] {
                var bad = query; bad.name = name
                do { _ = try await client.search(bad); throw RadioError.message("FAIL: accepted \(name)") }
                catch let error as RadioError {
                    if error.localizedDescription.hasPrefix("FAIL:") { throw error }
                    count += 1; print("PASS: Reject \(name) response")
                } catch { count += 1; print("PASS: Reject \(name) response") }
            }
            var slow = query; slow.name = "slow"
            let start = Date()
            let pending = Task { try await client.search(slow) }
            try await Task.sleep(nanoseconds: 150_000_000)
            pending.cancel()
            do { _ = try await pending.value; throw RadioError.message("FAIL: cancelled search returned data") }
            catch is CancellationError { try check(Date().timeIntervalSince(start) < 3, "Cancellation ends a slow request promptly") }
            for index in 0..<7 { var item = query; item.name = "cache-\(index)"; _ = try await client.search(item) }
            try check(!(try await client.search(query)).cached, "Cache evicts old pages after six searches")
            let (before, _) = try await URLSession.shared.data(from: base.appendingPathComponent("counts"))
            let beforeCounts = try JSONDecoder().decode([String: Int].self, from: before)
            try check(!beforeCounts.keys.contains { $0.hasPrefix("/json/url/") }, "Browsing never reports station plays")
            await client.countPlay("invalid/identifier")
            await client.countPlay("00000000-0000-0000-0000-000000000001")
            let (after, _) = try await URLSession.shared.data(from: base.appendingPathComponent("counts"))
            let counts = try JSONDecoder().decode([String: Int].self, from: after)
            try check(counts["/json/url/00000000-0000-0000-0000-000000000001"] == 1, "Explicit play reports one valid station click")
            print("\(count) network checks passed.")
        } catch {
            fputs("\(error.localizedDescription)\n", stderr); exit(1)
        }
    }
}
