// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "EasyVMCore",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "EasyVMCore", targets: ["EasyVMCore"]),
    ],
    targets: [
        .target(
            name: "EasyVMCore",
            path: "EasyVM/EasyVM/Core/VMKit",
            exclude: [
                "Catalog",
                "Model/VMModel.swift",
                "Model/VMOSType.swift",
                "Model/Fields/VMModelFieldAudioDevice.swift",
                "Model/Fields/VMModelFieldCPU.swift",
                "Model/Fields/VMModelFieldDirectorySharingDevice.swift",
                "Model/Fields/VMModelFieldGraphicDevice.swift",
                "Model/Fields/VMModelFieldMemory.swift",
                "Model/Fields/VMModelFieldPointingDevice.swift",
                "Model/Fields/VMModelFieldStorageDevice.swift",
                "OS",
                "VMOSCreator.swift",
                "VMOSDownloader.swift",
                "VMOSRunner.swift",
            ],
            sources: [
                "Common/VMOSResultVoid.swift",
                "Common/VMOSHelper.swift",
                "Common/VMRunningRegistry.swift",
                "Model/Fields/VMModelFieldNetworkDevice.swift",
                "Snapshot/VMSnapshotManager.swift",
            ]
        ),
        .testTarget(
            name: "EasyVMCoreTests",
            dependencies: ["EasyVMCore"]
        ),
    ]
)
