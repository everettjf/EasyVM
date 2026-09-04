// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "EZVMCore",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "EZVMCore", targets: ["EZVMCore"]),
        .library(name: "EZVMCLIKit", targets: ["EZVMCLIKit"]),
        .executable(name: "ezvm", targets: ["ezvm"]),
        .executable(name: "omarchy-factory-tool", targets: ["OmarchyFactoryTool"]),
        .executable(name: "omarchy-rollback-acceptance-tool", targets: ["OmarchyRollbackAcceptanceTool"]),
    ],
    targets: [
        .target(
            name: "EZVMCore",
            path: "EZVM/EZVM/Core/VMKit",
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
                "GuestAgent/VMGuestAgentHostClient.swift",
                "VMOSCreator.swift",
                "VMOSDownloader.swift",
                "VMOSRunner.swift",
            ],
            sources: [
                "Common/VMOSResultVoid.swift",
                "Common/VMOSHelper.swift",
                "Common/VMPortabilityManager.swift",
                "Common/VMRunningRegistry.swift",
                "GuestAgent/VMGuestAgentProtocol.swift",
                "GuestAgent/VMGuestAgentEnrollmentStore.swift",
                "Model/Fields/VMModelFieldNetworkDevice.swift",
                "Profile/VMOmarchyProfile.swift",
                "Profile/VMOmarchyStorageForecast.swift",
                "Profile/VMOmarchyFactoryManifest.swift",
                "Profile/VMOmarchyFactoryInstaller.swift",
                "Profile/VMOmarchyDiagnostics.swift",
                "Profile/VMOmarchyWorkspace.swift",
                "Profile/VMOmarchySharedFolderImporter.swift",
                "Profile/VMOmarchyVirtualMachineBuilder.swift",
                "Profile/VMOmarchyGuestAgentClient.swift",
                "Snapshot/VMSnapshotManager.swift",
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-weak_framework",
                    "-Xlinker", "DiskImageKit",
                ], .when(platforms: [.macOS])),
            ]
        ),
        .testTarget(
            name: "EZVMCoreTests",
            dependencies: ["EZVMCore"]
        ),
        .target(name: "EZVMCLIKit", path: "CLI/Kit"),
        .executableTarget(
            name: "ezvm",
            dependencies: ["EZVMCLIKit"],
            path: "CLI/Executable"
        ),
        .executableTarget(
            name: "OmarchyFactoryTool",
            dependencies: ["EZVMCore"],
            path: "Tools/OmarchyFactoryTool"
        ),
        .executableTarget(
            name: "OmarchyRollbackAcceptanceTool",
            dependencies: ["EZVMCore"],
            path: "Tools/OmarchyRollbackAcceptanceTool"
        ),
        .testTarget(
            name: "EZVMCLIKitTests",
            dependencies: ["EZVMCLIKit"]
        ),
    ]
)
