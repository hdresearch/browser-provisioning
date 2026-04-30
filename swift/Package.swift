// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "browser-provisioning-swift",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/hdresearch/swift-sdk.git", branch: "main"),
    ],
    targets: [
        .executableTarget(
            name: "main",
            dependencies: [.product(name: "VersSdkSDK", package: "swift-sdk")],
            path: "Sources"
        ),
    ]
)
