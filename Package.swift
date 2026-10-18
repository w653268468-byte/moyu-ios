// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MoyuReaderCore",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [.library(name: "ReaderCore", targets: ["ReaderCore"])],
    dependencies: [
        .package(url: "https://github.com/scinfu/SwiftSoup.git", exact: "2.7.7"),
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", exact: "0.9.19")
    ],
    targets: [
        .target(name: "ReaderCore", dependencies: ["SwiftSoup", "ZIPFoundation"], path: "Sources/ReaderCore"),
        .testTarget(name: "ReaderCoreTests", dependencies: ["ReaderCore"], path: "Tests/ReaderCoreTests")
    ]
)
