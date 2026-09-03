import Foundation
import Virtualization

public enum VMOmarchyVirtualMachineBuilder {
    public static func makeConfiguration(
        layout: VMOmarchyWorkspaceLayout,
        profile: VMOmarchyProfile,
        hostMemoryBytes: UInt64 = ProcessInfo.processInfo.physicalMemory,
        activeProcessorCount: Int = ProcessInfo.processInfo.activeProcessorCount
    ) throws -> VZVirtualMachineConfiguration {
        try buildConfiguration(
            layout: layout,
            profile: profile,
            hostMemoryBytes: hostMemoryBytes,
            activeProcessorCount: activeProcessorCount,
            validatesConfiguration: true
        )
    }

    static func makeUnvalidatedConfigurationForTesting(
        layout: VMOmarchyWorkspaceLayout,
        profile: VMOmarchyProfile,
        hostMemoryBytes: UInt64,
        activeProcessorCount: Int
    ) throws -> VZVirtualMachineConfiguration {
        try buildConfiguration(
            layout: layout,
            profile: profile,
            hostMemoryBytes: hostMemoryBytes,
            activeProcessorCount: activeProcessorCount,
            validatesConfiguration: false
        )
    }

    private static func buildConfiguration(
        layout: VMOmarchyWorkspaceLayout,
        profile: VMOmarchyProfile,
        hostMemoryBytes: UInt64,
        activeProcessorCount: Int,
        validatesConfiguration: Bool
    ) throws -> VZVirtualMachineConfiguration {
        try profile.validate()
        let resources = profile.resources(
            forHostMemory: hostMemoryBytes,
            activeProcessorCount: activeProcessorCount
        )
        let configuration = VZVirtualMachineConfiguration()
        configuration.cpuCount = min(
            max(resources.cpuCount, VZVirtualMachineConfiguration.minimumAllowedCPUCount),
            VZVirtualMachineConfiguration.maximumAllowedCPUCount
        )
        configuration.memorySize = min(
            max(resources.memoryBytes, VZVirtualMachineConfiguration.minimumAllowedMemorySize),
            VZVirtualMachineConfiguration.maximumAllowedMemorySize
        )

        let bootLoader = VZEFIBootLoader()
        if FileManager.default.fileExists(atPath: layout.efiVariableStore.path) {
            bootLoader.variableStore = VZEFIVariableStore(url: layout.efiVariableStore)
        } else {
            try FileManager.default.createDirectory(at: layout.boot, withIntermediateDirectories: true)
            bootLoader.variableStore = try VZEFIVariableStore(
                creatingVariableStoreAt: layout.efiVariableStore,
                options: []
            )
        }
        configuration.bootLoader = bootLoader

        guard let machineIdentifier = VZGenericMachineIdentifier(
            dataRepresentation: try Data(contentsOf: layout.machineIdentifier)
        ) else {
            throw VMOmarchyVirtualMachineBuilderError.invalidMachineIdentifier
        }
        let platform = VZGenericPlatformConfiguration()
        platform.machineIdentifier = machineIdentifier
        configuration.platform = platform

        let diskAttachment = try VZDiskImageStorageDeviceAttachment(
            url: layout.disk,
            readOnly: false,
            cachingMode: .automatic,
            synchronizationMode: .full
        )
        configuration.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: diskAttachment)]

        let graphics = VZVirtioGraphicsDeviceConfiguration()
        graphics.scanouts = [VZVirtioGraphicsScanoutConfiguration(widthInPixels: 1920, heightInPixels: 1200)]
        configuration.graphicsDevices = [graphics]
        configuration.keyboards = [VZUSBKeyboardConfiguration()]
        configuration.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]
        configuration.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        configuration.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]
        configuration.socketDevices = [VZVirtioSocketDeviceConfiguration()]

        let enrollmentDirectory = VZSharedDirectory(url: layout.enrollment, readOnly: true)
        let enrollmentShare = VZSingleDirectoryShare(directory: enrollmentDirectory)
        let enrollmentDevice = VZVirtioFileSystemDeviceConfiguration(
            tag: VMGuestAgentEnrollmentStore.sharedDirectoryTag
        )
        enrollmentDevice.share = enrollmentShare
        configuration.directorySharingDevices = [enrollmentDevice]

        let network = VZVirtioNetworkDeviceConfiguration()
        network.attachment = VZNATNetworkDeviceAttachment()
        network.macAddress = VZMACAddress.randomLocallyAdministered()
        configuration.networkDevices = [network]

        let audio = VZVirtioSoundDeviceConfiguration()
        let output = VZVirtioSoundDeviceOutputStreamConfiguration()
        output.sink = VZHostAudioOutputStreamSink()
        audio.streams = [output]
        configuration.audioDevices = [audio]

        if validatesConfiguration { try configuration.validate() }
        return configuration
    }
}

public enum VMOmarchyVirtualMachineBuilderError: Error, Equatable {
    case invalidMachineIdentifier
}
