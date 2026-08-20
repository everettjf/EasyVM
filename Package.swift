// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "EasyVMCore",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "EasyVMCore", targets: ["EasyVMCore"]),
    ],
    targets: [
        .target(
            name: "EasyVMCore",
            path: "EasyVM/EasyVM/Core/VMKit",
            exclude: [
                "Catalog",
                "Model",
                "OS",
                "Common/VMOSHelper.swift",
                "Common/VMRunningRegistry.swift",
                "VMOSCreator.swift",
                "VMOSDownloader.swift",
                "VMOSRunner.swift",
            ],
            sources: [
                "Common/VMOSResultVoid.swift",
                "Snapshot/VMSnapshotManager.swift",
            ]
        ),
        .testTarget(
            name: "EasyVMCoreTests",
            dependencies: ["EasyVMCore"]
        ),
    ]
)
