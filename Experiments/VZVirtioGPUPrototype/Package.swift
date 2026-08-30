// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "VZVirtioGPUPrototype",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "EZVMVirGLRuntime", targets: ["EZVMVirGLRuntime"]),
        .executable(name: "vz-virtio-gpu-prototype", targets: ["VZVirtioGPUPrototype"]),
    ],
    targets: [
        .target(
            name: "CVirGLBridge",
            linkerSettings: [.linkedLibrary("dl")]
        ),
        .target(
            name: "EZVMVirGLRuntime",
            dependencies: ["CVirGLBridge"],
            path: "Sources/VZVirtioGPUPrototype"
        ),
        .executableTarget(
            name: "VZVirtioGPUPrototype",
            dependencies: ["EZVMVirGLRuntime"],
            path: "Sources/VZVirtioGPUPrototypeRunner"
        ),
        .testTarget(
            name: "VZVirtioGPUPrototypeTests",
            dependencies: ["EZVMVirGLRuntime"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
