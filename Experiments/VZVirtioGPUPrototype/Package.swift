// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "VZVirtioGPUPrototype",
    platforms: [.macOS("27.0")],
    products: [
        .executable(name: "vz-virtio-gpu-prototype", targets: ["VZVirtioGPUPrototype"]),
    ],
    targets: [
        .target(
            name: "CVirGLBridge",
            linkerSettings: [.linkedLibrary("dl")]
        ),
        .executableTarget(
            name: "VZVirtioGPUPrototype",
            dependencies: ["CVirGLBridge"]
        ),
        .testTarget(
            name: "VZVirtioGPUPrototypeTests",
            dependencies: ["VZVirtioGPUPrototype"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
