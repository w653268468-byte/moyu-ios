// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MoyuReaderCore",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [.library(name: "ReaderCore", targets: ["ReaderCore"])],
    dependencies: [
        .package(url: "https://github.com/scinfu/SwiftSoup.git", exact: "2.7.7"),
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", exact: "0.9.19"),
        .package(path: "Vendor/QuickJS-Swift")
    ],
    targets: [
        .target(name: "CReaderXML", path: "Sources/CReaderXML", publicHeadersPath: "include", linkerSettings: [.linkedLibrary("xml2")]),
        .target(name: "CReaderMobi", path: "Sources/CReaderMobi", exclude: ["Vendor/COPYING", "Vendor/UPSTREAM.md", "Vendor/GPL-3.0.txt"], publicHeadersPath: "include", linkerSettings: [.linkedLibrary("xml2"), .linkedLibrary("z")]),
        .target(name: "ReaderCore", dependencies: ["SwiftSoup", "ZIPFoundation", "CReaderXML", "CReaderMobi", .product(name: "QuickJS", package: "QuickJS-Swift")], path: "Sources/ReaderCore", resources: [.copy("ScriptAssets")]),
        .testTarget(name: "ReaderCoreTests", dependencies: ["ReaderCore"], path: "Tests/ReaderCoreTests")
    ]
)
