import Foundation

/// Compares this build with the newest version listed in the source repository's changelog.
/// The check is a single plain GET of a public text file; nothing about the user or the app is sent.
enum UpdateCheck {
    static let repository = URL(string: "https://github.com/darin2036/radiopocket")!
    static let changelog = URL(string: "https://raw.githubusercontent.com/darin2036/radiopocket/main/Resources/CHANGELOG.txt")!
    /// Launch checks run at most this often.
    static let launchInterval: TimeInterval = 24 * 60 * 60

    enum Outcome: Equatable {
        case available(Release)
        case current
    }

    /// Numeric `major.minor.patch` comparison; missing parts count as 0 and non-numeric versions never compare as newer.
    static func isNewer(_ candidate: String, than installed: String) -> Bool {
        func parts(_ version: String) -> [Int]? {
            let numbers = version.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
            return numbers.contains(nil) || numbers.isEmpty ? nil : numbers.compactMap { $0 }
        }
        guard let new = parts(candidate), let old = parts(installed) else { return false }
        for i in 0..<max(new.count, old.count) {
            let a = i < new.count ? new[i] : 0, b = i < old.count ? old[i] : 0
            if a != b { return a > b }
        }
        return false
    }

    /// The first release in a changelog is the newest.
    static func outcome(changelog text: String, installed: String) -> Outcome? {
        guard let latest = Changelog.parse(text).first else { return nil }
        return isNewer(latest.version, than: installed) ? .available(latest) : .current
    }

    static func shouldCheckAtLaunch(last: Date?, now: Date = Date()) -> Bool {
        guard let last else { return true }
        return now.timeIntervalSince(last) >= launchInterval || last > now
    }

    static func fetch(installed: String) async throws -> Outcome {
        var request = URLRequest(url: changelog, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("text/plain", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let text = String(data: data, encoding: .utf8),
              let outcome = outcome(changelog: text, installed: installed) else {
            throw RadioError.message("RadioPocket couldn’t read the latest version information. Try again later.")
        }
        return outcome
    }
}
