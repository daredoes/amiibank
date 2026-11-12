// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AmiiboKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "AmiiboKit", targets: ["AmiiboKit"])],
    targets: [
        .target(name: "AmiiboKit"),
        .testTarget(name: "AmiiboKitTests", dependencies: ["AmiiboKit"]),
    ]
)
