// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "quill",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.7.0"),
    ],
    targets: [
        .testTarget(name: "quillTests", dependencies: ["quill"]),
        .executableTarget(
            name: "quill",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            exclude: ["Info.plist"]

        ),
    ]
)
