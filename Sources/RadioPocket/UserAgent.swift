import Foundation

/// Identifies RadioPocket to the servers it talks to, so station operators can see it in their logs and find the project.
enum UserAgent {
    static let home = "https://github.com/darin2036/radiopocket"
    static let value: String = {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        return "RadioPocket/\(version) (+\(home))"
    }()
}
