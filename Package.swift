// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ConsistencyKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "ConsistencyKit", targets: ["ConsistencyKit"]),
    ],
    targets: [
        .target(name: "ConsistencyKit"),
        .testTarget(name: "ConsistencyKitTests", dependencies: ["ConsistencyKit"]),
    ]
)
