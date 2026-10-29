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
            // Saved station lists: instant from disk, stale pages refreshed quietly, offline falls back.
            let saveDir = FileManager.default.temporaryDirectory.appendingPathComponent("radiopocket-saved-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: saveDir) }
            let store = StationCache(directory: saveDir)
            let firstRun = RadioDirectory(baseURLs: [base], cache: store)
            var browse = DirectoryQuery(); browse.sourceID = "radio-browser"
            // Only the loopback fixture: the other built-in directories are switched off so this never reaches the internet.
            let onlyFixture = ["somafm", "laut-fm", "radio-paradise", "curated-streams"].map { DirectorySource(id: $0, name: $0, kind: .somaFM, enabled: false) }
            await firstRun.configure(onlyFixture)
            let live = try await firstRun.search(browse)
            try check(!live.cached && live.stations.count == 100, "The first browse of a view is fetched live")
            let afterRestart = RadioDirectory(baseURLs: [URL(string: "http://127.0.0.1:1")!], cache: store)
            await afterRestart.configure(onlyFixture)
            let fromDisk = try await afterRestart.search(browse)
            try check(fromDisk.cached && fromDisk.stations.count == 100 && fromDisk.updated != nil, "After a restart the view opens from disk without the network")
            var typed = browse; typed.name = "network"
            let typedFirst = try await firstRun.search(typed)
            try check(typedFirst.stations.count == 100 && (try? FileManager.default.contentsOfDirectory(atPath: saveDir.path).count) == 1, "Typed searches are not saved")
            let key = store.key(for: browse, sources: ["radio-browser@"])!
            try check((try? FileManager.default.contentsOfDirectory(atPath: saveDir.path)) == [key + ".json"], "Saved pages are keyed by the view and the directories that fed it")
            let file = saveDir.appendingPathComponent(key + ".json")
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-8 * 3600)], ofItemAtPath: file.path)
            let stale = try await firstRun.search(browse)
            try check(stale.cached && stale.stations.count == 100, "A stale page is shown immediately")
            var refreshed = false
            for _ in 0..<40 where !refreshed { try await Task.sleep(nanoseconds: 100_000_000); refreshed = (store.age(of: key) ?? 99_999) < 60 }
            try check(refreshed, "A stale page is refreshed in the background")
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-9 * 86_400)], ofItemAtPath: file.path)
            let offline = RadioDirectory(baseURLs: [URL(string: "http://127.0.0.1:1")!], cache: store)
            await offline.configure(onlyFixture)
            try check(try await offline.search(browse).stations.count == 100, "An expired page is still the fallback when the directory is unreachable")
            do { _ = try await offline.search(browse, refresh: true); throw RadioError.message("FAIL: refresh hid an outage") }
            catch let error as RadioError { if error.localizedDescription.hasPrefix("FAIL:") { throw error }; count += 1; print("PASS: Refresh reports an outage instead of showing saved pages") }
            catch { count += 1; print("PASS: Refresh reports an outage instead of showing saved pages") }
            await firstRun.warm()
            var warmed = 0
            for _ in 0..<300 where warmed < 9 { try await Task.sleep(nanoseconds: 100_000_000); warmed = (try? FileManager.default.contentsOfDirectory(atPath: saveDir.path).filter { $0.hasSuffix(".json") }.count) ?? 0 }
            try check(warmed >= 9, "Warming saves the opening views one page at a time")
            print("\(count) network checks passed.")
        } catch {
            fputs("\(error.localizedDescription)\n", stderr); exit(1)
        }
    }
}
