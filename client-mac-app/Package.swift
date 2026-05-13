// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "BloomDictate",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "BloomDictate",
            path: "Sources/BloomDictate"
        )
    ]
)
