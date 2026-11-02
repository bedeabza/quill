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
        .target(name: "QuillEchoDSP", exclude: ["vendor/COPYING", "vendor/README.quill"],
            cSettings: [.headerSearchPath("vendor"), .define("FLOATING_POINT"),
                        .define("USE_KISS_FFT"), .define("EXPORT", to: ""), .define("VAR_ARRAYS")]),
        .testTarget(name: "quillTests", dependencies: ["quill"]),
        .executableTarget(
            name: "quill",
            dependencies: [
                "QuillEchoDSP",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            exclude: ["Info.plist"]

        ),
    ]
)
