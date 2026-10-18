// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MoyuReaderCore",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [.library(name: "ReaderCore", targets: ["ReaderCore"])],
    dependencies: [.package(url: "https://github.com/scinfu/SwiftSoup.git", exact: "2.7.7")],
    targets: [
        .target(name: "ReaderCore", dependencies: ["SwiftSoup"], path: "Sources/ReaderCore"),
        .testTarget(name: "ReaderCoreTests", dependencies: ["ReaderCore"], path: "Tests/ReaderCoreTests")
    ]
)
