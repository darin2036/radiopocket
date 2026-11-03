import Foundation

/// Identifies RadioPocket to the servers it talks to, so station operators can see it in their logs and find the project.
enum UserAgent {
    static let home = "https://github.com/darin2036/radiopocket"
    static let value: String = {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        return "RadioPocket/\(version) (+\(home))"
    }()
    /// What Safari sends. A few hosts refuse unknown agents but serve browsers.
    static let browser = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    private static let defaultsKey = "streamUserAgents"

    /// Agents to try for a host, in order: RadioPocket, a browser, then none (the system default).
    /// A choice that worked before for the host goes first.
    static func ladder(for host: String?) -> [String?] {
        let all: [String?] = [value, browser, nil]
        guard let host, let saved = UserDefaults.standard.dictionary(forKey: defaultsKey)?[host.lowercased()] as? Int,
              all.indices.contains(saved) else { return all }
        return [all[saved]] + all.enumerated().filter { $0.offset != saved }.map { $0.element }
    }

    static func remember(_ agent: String?, for host: String?) {
        guard let host else { return }
        let index = agent == nil ? 2 : (agent == browser ? 1 : 0)
        var saved = UserDefaults.standard.dictionary(forKey: defaultsKey) ?? [:]
        let key = host.lowercased()
        if index == 0 { guard saved[key] != nil else { return }; saved[key] = nil } else { guard saved[key] as? Int != index else { return }; saved[key] = index }
        if saved.count > 500 { saved = [key: index] }
        UserDefaults.standard.set(saved, forKey: defaultsKey)
    }
}
