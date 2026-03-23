// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ClickForge",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "ClickForge",
            path: "ClickForge",
            exclude: ["Info.plist"],
            resources: [
                .copy("Assets.xcassets")
            ],
            swiftSettings: [
                .unsafeFlags(["-parse-as-library"])
            ]
        )
    ]
)
