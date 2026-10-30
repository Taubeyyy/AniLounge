// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "AniCore",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [.library(name: "AniCore", targets: ["AniCore"])],
    dependencies: [.package(url: "https://github.com/scinfu/SwiftSoup.git", exact: "2.8.8")],
    targets: [
        .target(name: "AniCore", dependencies: ["SwiftSoup"]),
        .testTarget(name: "AniCoreTests", dependencies: ["AniCore"], resources: [.copy("Fixtures")])
    ]
)
