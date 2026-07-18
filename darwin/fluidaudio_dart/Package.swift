// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "fluidaudio_dart",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "fluidaudio-dart", targets: ["fluidaudio_dart"])
    ],
    dependencies: [
        .package(name: "FlutterFramework", path: "../FlutterFramework"),
        .package(
            url: "https://github.com/FluidInference/FluidAudio.git",
            .upToNextMinor(from: "0.15.5")
        ),
    ],
    targets: [
        .target(
            name: "fluidaudio_dart",
            dependencies: [
                .product(name: "FlutterFramework", package: "FlutterFramework"),
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
