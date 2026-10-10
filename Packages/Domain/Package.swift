// swift-tools-version: 6.0
import PackageDescription

// アプリの判断ロジック。Foundation以外に依存しない純粋関数だけを置く
let package = Package(
    name: "Domain",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "Domain", targets: ["Domain"]),
    ],
    targets: [
        .target(name: "Domain"),
        .testTarget(name: "DomainTests", dependencies: ["Domain"]),
    ]
)
