// swift-tools-version:5.10
//
// DroidScreen macOS host — Milestones 1, 2, 4 (virtual display, video streaming, input).
//
// Targets:
//   CGVirtualDisplayBridge  Objective-C shim around CoreGraphics' private CGVirtualDisplay
//                           classes. Resolves every class at runtime (NSClassFromString), so
//                           nothing private is referenced at link time.
//   VirtualDisplayKit       Swift API: configuration, lifecycle, inspection, self-test.
//   StreamKit               Milestone 2: ScreenCaptureKit capture → VideoToolbox encode → TCP stream.
//   InputKit                Milestone 4: touch/keyboard → CGEvent injection on the virtual display.
//   droidscreen-vd          Command-line tool: probe / list / create / selftest / serve.
//   DroidScreenHost         Minimal SwiftUI host app (bundled by scripts/build-app.sh).

import PackageDescription

let package = Package(
    name: "DroidScreenHost",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "VirtualDisplayKit", targets: ["VirtualDisplayKit"]),
        .library(name: "StreamKit", targets: ["StreamKit"]),
        .library(name: "InputKit", targets: ["InputKit"]),
        .executable(name: "droidscreen-vd", targets: ["droidscreen-vd"]),
        .executable(name: "DroidScreenHost", targets: ["DroidScreenHost"]),
    ],
    targets: [
        .target(
            name: "CGVirtualDisplayBridge",
            path: "Sources/CGVirtualDisplayBridge",
            linkerSettings: [
                .linkedFramework("CoreGraphics"),
                .linkedFramework("Foundation"),
            ]
        ),
        .target(
            name: "VirtualDisplayKit",
            dependencies: ["CGVirtualDisplayBridge"],
            path: "Sources/VirtualDisplayKit",
            linkerSettings: [.linkedFramework("AppKit")]
        ),
        .target(
            name: "InputKit",
            path: "Sources/InputKit",
            linkerSettings: [.linkedFramework("ApplicationServices")]
        ),
        .target(
            name: "StreamKit",
            dependencies: ["VirtualDisplayKit", "InputKit"],
            path: "Sources/StreamKit",
            linkerSettings: [
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("VideoToolbox"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("Network"),
            ]
        ),
        .executableTarget(
            name: "droidscreen-vd",
            dependencies: ["VirtualDisplayKit", "StreamKit"],
            path: "Sources/droidscreen-vd"
        ),
        .executableTarget(
            name: "DroidScreenHost",
            dependencies: ["VirtualDisplayKit", "StreamKit", "InputKit"],
            path: "Sources/DroidScreenHost"
        ),
        .testTarget(
            name: "VirtualDisplayKitTests",
            dependencies: ["VirtualDisplayKit"],
            path: "Tests/VirtualDisplayKitTests"
        ),
        .testTarget(
            name: "StreamKitTests",
            dependencies: ["StreamKit", "VirtualDisplayKit"],
            path: "Tests/StreamKitTests"
        ),
        .testTarget(
            name: "InputKitTests",
            dependencies: ["InputKit"],
            path: "Tests/InputKitTests"
        ),
    ]
)
