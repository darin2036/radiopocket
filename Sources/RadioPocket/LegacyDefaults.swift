import Foundation

/// Early builds used the bundle identifier local.radiopocket.player. Copies their window positions and
/// other macOS preferences into the current identifier once, so nothing is lost by the rename.
/// Station favorites and settings live in Application Support and are not affected.
enum LegacyDefaults {
    static let oldDomain = "local.radiopocket.player"
    private static let marker = "RadioPocketMigratedFromLocalDomain"

    static func migrate(defaults: UserDefaults = .standard, currentDomain: String? = Bundle.main.bundleIdentifier) {
        guard let currentDomain, currentDomain != oldDomain, !defaults.bool(forKey: marker) else { return }
        if let old = defaults.persistentDomain(forName: oldDomain) {
            for (key, value) in old where defaults.object(forKey: key) == nil { defaults.set(value, forKey: key) }
        }
        defaults.set(true, forKey: marker)
    }
}
