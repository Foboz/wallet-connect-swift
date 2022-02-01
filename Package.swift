// swift-tools-version:5.4
import PackageDescription

let package = Package(
    name: "WalletConnect",
    platforms: [
        .iOS(.v13),
        .macOS(.v10_13),
    ],
    products: [
        .library(name: "WalletConnect", targets: ["WalletConnect"]),
    ],
    dependencies: [
        .package(url: "https://github.com/krzyzanowskim/CryptoSwift", from: "1.4.0"),
        .package(url: "https://github.com/daltoniam/Starscream", from: "4.0.0"),
    ],
    targets: [
        .target(
            name: "WalletConnect",
            dependencies: ["CryptoSwift", "Starscream"],
            path: "WalletConnect",
            exclude: [
                "Info.plist"
            ]
        ),
    ]
)
