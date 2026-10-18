// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MoyuReaderCore",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [.library(name: "ReaderCore", targets: ["ReaderCore"])],
    dependencies: [
        .package(url: "https://github.com/scinfu/SwiftSoup.git", exact: "2.7.7"),
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", exact: "0.9.19"),
        .package(url: "https://github.com/zqqf16/QuickJS-Swift.git", revision: "50eb132d6bc89736f478cf8336948fb62133a264")
    ],
    targets: [
        .target(name: "CReaderXML", path: "Sources/CReaderXML", publicHeadersPath: "include", linkerSettings: [.linkedLibrary("xml2")]),
        .target(name: "ReaderCore", dependencies: ["SwiftSoup", "ZIPFoundation", "CReaderXML", .product(name: "QuickJS", package: "QuickJS-Swift")], path: "Sources/ReaderCore"),
        .testTarget(name: "ReaderCoreTests", dependencies: ["ReaderCore"], path: "Tests/ReaderCoreTests")
    ]
)
