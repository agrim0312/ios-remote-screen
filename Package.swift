// swift-tools-version:5.10
import Foundation
import PackageDescription

// CoreDeviceInput calls Apple's private CoreDevice framework (installed with Xcode) through
// hand-written module interfaces in Interfaces/, reconstructed with REA from exported symbols.
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let privateFrameworks = "/Library/Developer/PrivateFrameworks"
let coreDeviceFrameworks = privateFrameworks + "/CoreDevice.framework/Versions/A/Frameworks"

let package = Package(
    name: "ios-remote-screen",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ios-remote-screen", targets: ["ios-remote-screen"]),
    ],
    targets: [
        .target(
            name: "CoreDeviceInput",
            swiftSettings: [.unsafeFlags(["-I", root + "/Interfaces"])],
            linkerSettings: [.unsafeFlags([
                "-F", privateFrameworks, "-F", coreDeviceFrameworks,
                "-framework", "CoreDevice", "-framework", "UniversalHID",
                "-Xlinker", "-rpath", "-Xlinker", privateFrameworks,
                "-Xlinker", "-rpath", "-Xlinker", coreDeviceFrameworks,
            ])]
        ),
        .target(name: "RemoteScreenCore", dependencies: ["CoreDeviceInput"]),
        .executableTarget(name: "ios-remote-screen", dependencies: ["RemoteScreenCore"]),
        .testTarget(name: "RemoteScreenCoreTests", dependencies: ["RemoteScreenCore"]),
    ]
)
