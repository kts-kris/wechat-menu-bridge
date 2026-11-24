// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "WeChatMenuBridge",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "WeChatMenuBridge", targets: ["WeChatMenu"])],
    targets: [
        .executableTarget(name: "WeChatMenu"),
        .testTarget(name: "WeChatMenuTests", dependencies: ["WeChatMenu"]),
    ]
)
