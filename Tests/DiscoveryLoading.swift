import AppKit

@main
struct DiscoveryLoadingChecks {
    @MainActor static func main() {
        _ = NSApplication.shared
        let panel = DiscoverPanel(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        var settings = Library.State(); settings.discoveryArtwork = false
        panel.configure(state: settings)
        func views(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(views) }
        func contains(_ text: String) -> Bool { views(panel).compactMap { ($0 as? NSTextField)?.stringValue }.contains(text) }
        func check(_ condition: Bool, _ message: String) {
            guard condition else { fputs("FAIL: \(message)\n", stderr); exit(1) }
            print("PASS: \(message)")
        }
        let row = RadioListing(id: "fixture", name: "Discovery fixture station", address: "https://fixture.example/live", tags: "jazz", country: "", countryCode: "", codec: "MP3", bitrate: 192, votes: 0, clicks: 0, hls: false, sourceName: nil)
        let pick = DiscoveryPick(listing: row, reason: "A test recommendation", sources: [], fetched: Date())
        let feed = DiscoveryFeed(shelves: [DiscoveryShelf(title: "Your next frequency", subtitle: "", picks: [pick])], interests: [], basis: "", indexed: 1, updated: nil)
        panel.render(feed, favorites: [])
        check(contains(row.name), "Discovery fixture is initially rendered")
        panel.setMoods(true)
        check(!contains(row.name), "Switching to Moods synchronously removes discovery cards")
        panel.beginLoading()
        check(contains("Finding your mood…"), "Moods has its own loading state")
        panel.beginLoading()
        check(views(panel).compactMap { $0 as? NSProgressIndicator }.count <= 1, "Repeated loading does not accumulate animation views")
        panel.loadingFailed()
        check(contains("Moods couldn’t load") && !contains("Finding your mood…"), "Failure replaces the loading state with recovery guidance")
        panel.beginLoading()
        panel.render(DiscoveryFeed(shelves: [], interests: [], basis: "", indexed: 0, updated: nil), favorites: [])
        check(!contains("Finding your mood…") && views(panel).compactMap { $0 as? NSProgressIndicator }.isEmpty, "Completed empty feed removes the loading animation")
        panel.setMoods(false); panel.beginLoading()
        check(contains("Finding your next frequency…"), "Switching back uses the Discovery loading state")
        panel.render(feed, favorites: []); panel.beginLoading()
        check(contains(row.name) && !contains("Finding your next frequency…"), "Background refresh preserves existing content without flashing a loader")
        let before = panel.recommendedStations.map(\.address)
        panel.updateFavorites([row.station])
        check(panel.recommendedStations.map(\.address) == before && contains(row.name), "Favorite changes preserve the recommendation snapshot and order")
        panel.releaseContent()
        check(panel.recommendedStations.isEmpty && !contains(row.name), "Releasing a closed library discards its feed and card views")
        panel.beginLoading()
        check(contains("Finding your next frequency…"), "Released content can load again without retaining stale cards")
        print("11 discovery loading checks passed.")
    }
}
