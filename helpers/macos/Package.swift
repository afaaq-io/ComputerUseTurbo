// swift-tools-version:6.0
//
// Computer Use Turbo — macOS helper.
//
//  * TurboCore    pure logic (protocol types, framing, tree model, serializer, diff,
//                 index identity, safety policy, key chords, approval store, error
//                 codes, design tokens). No AppKit / Accessibility imports.
//  * TurboHelper  the background agent app: socket server, AX reader, ScreenCaptureKit
//                 screenshots, CGEvent input, approval card, overlay, live preview.
//                 Packaged into Computer Use Turbo.app by scripts/build-app.sh.
import PackageDescription

let package = Package(
    name: "TurboHelper",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TurboCore", targets: ["TurboCore"]),
        .executable(name: "TurboHelper", targets: ["TurboHelper"]),
    ],
    targets: [
        .target(
            name: "TurboCore",
            path: "Sources/TurboCore"
        ),
        .testTarget(
            name: "TurboCoreTests",
            dependencies: ["TurboCore"],
            path: "Tests/TurboCoreTests"
        ),
        .executableTarget(
            name: "TurboHelper",
            dependencies: ["TurboCore"],
            path: "Sources/TurboHelper",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("Carbon"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreServices"),
                .linkedFramework("IOKit"),
                .linkedFramework("ImageIO"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("UniformTypeIdentifiers"),
            ]
        ),
    ],
    swiftLanguageModes: [.v5]
)
