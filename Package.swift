// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "RadioPocket",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "RadioPocket", targets: ["RadioPocket"])],
    targets: [
        .target(name: "CEQ"),
        .target(name: "CVorbis", cSettings: [.unsafeFlags(["-w"])]),
        .executableTarget(name: "RadioPocket", dependencies: ["CEQ", "CVorbis"])
    ]
)
