// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "EyeBreak",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "EyeBreak",
            path: "Sources/EyeBreak",
            exclude: ["Info.plist", "icon.svg"],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/EyeBreak/Info.plist"
                ])
            ]
        )
    ]
)
