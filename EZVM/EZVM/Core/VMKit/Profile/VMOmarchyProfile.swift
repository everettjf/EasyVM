import Foundation

/// Versioned product contract shared by EZVM and the dedicated EZVM Omarchy app.
/// It deliberately contains product policy, not mutable per-workspace state.
public struct VMOmarchyProfile: Codable, Equatable {
    public static let currentSchemaVersion = 1

    public struct ResourceTier: Codable, Equatable {
        public let hostMemoryBytes: UInt64
        public let cpuCount: Int
        public let memoryBytes: UInt64

        public init(hostMemoryBytes: UInt64, cpuCount: Int, memoryBytes: UInt64) {
            self.hostMemoryBytes = hostMemoryBytes
            self.cpuCount = cpuCount
            self.memoryBytes = memoryBytes
        }
    }

    public struct FactoryImage: Codable, Equatable {
        public let manifestURL: URL
        public let signingKeyID: String
        public let architecture: String
        public let maximumDownloadBytes: UInt64

        public init(manifestURL: URL, signingKeyID: String, architecture: String, maximumDownloadBytes: UInt64) {
            self.manifestURL = manifestURL
            self.signingKeyID = signingKeyID
            self.architecture = architecture
            self.maximumDownloadBytes = maximumDownloadBytes
        }
    }

    public let schemaVersion: Int
    public let productID: String
    public let minimumHostMajorVersion: Int
    public let diskCapacityBytes: UInt64
    public let resourceTiers: [ResourceTier]
    public let requiredGuestCapabilities: [String]
    public let factoryImage: FactoryImage

    public init(
        schemaVersion: Int,
        productID: String,
        minimumHostMajorVersion: Int,
        diskCapacityBytes: UInt64,
        resourceTiers: [ResourceTier],
        requiredGuestCapabilities: [String],
        factoryImage: FactoryImage
    ) {
        self.schemaVersion = schemaVersion
        self.productID = productID
        self.minimumHostMajorVersion = minimumHostMajorVersion
        self.diskCapacityBytes = diskCapacityBytes
        self.resourceTiers = resourceTiers
        self.requiredGuestCapabilities = requiredGuestCapabilities
        self.factoryImage = factoryImage
    }

    public func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw ValidationError.unsupportedSchema(schemaVersion)
        }
        guard productID == "com.everettjf.ezvm.omarchy" else {
            throw ValidationError.invalidProductID
        }
        guard minimumHostMajorVersion >= 27,
              diskCapacityBytes >= 32 * 1_024 * 1_024 * 1_024 else {
            throw ValidationError.invalidPlatformPolicy
        }
        guard !resourceTiers.isEmpty,
              resourceTiers == resourceTiers.sorted(by: { $0.hostMemoryBytes < $1.hostMemoryBytes }),
              resourceTiers.allSatisfy({
                  $0.hostMemoryBytes > $0.memoryBytes
                      && $0.cpuCount >= 2
                      && $0.memoryBytes >= 4 * 1_024 * 1_024 * 1_024
              }) else {
            throw ValidationError.invalidResourcePolicy
        }
        guard factoryImage.manifestURL.scheme == "https",
              factoryImage.architecture == "arm64",
              !factoryImage.signingKeyID.isEmpty,
              factoryImage.maximumDownloadBytes > 0 else {
            throw ValidationError.invalidFactoryImage
        }
        guard Set(requiredGuestCapabilities).count == requiredGuestCapabilities.count,
              requiredGuestCapabilities.allSatisfy({ !$0.isEmpty }) else {
            throw ValidationError.invalidCapabilities
        }
    }

    public func resources(forHostMemory hostMemoryBytes: UInt64, activeProcessorCount: Int) -> ResourceTier {
        let selected = resourceTiers.last(where: { hostMemoryBytes >= $0.hostMemoryBytes })
            ?? resourceTiers[0]
        return ResourceTier(
            hostMemoryBytes: selected.hostMemoryBytes,
            cpuCount: min(selected.cpuCount, max(2, activeProcessorCount - 2)),
            memoryBytes: min(selected.memoryBytes, hostMemoryBytes / 2)
        )
    }

    /// Capabilities a signed factory image must expose across its full
    /// lifecycle. Owner provisioning is intentionally absent from steady-state
    /// readiness because the Guest Agent removes it after setup completes.
    public var factoryGuestCapabilities: [String] {
        Array(Set(requiredGuestCapabilities + ["owner-provisioning-v1"])).sorted()
    }

    public enum ValidationError: Error, Equatable {
        case unsupportedSchema(Int)
        case invalidProductID
        case invalidPlatformPolicy
        case invalidResourcePolicy
        case invalidFactoryImage
        case invalidCapabilities
    }
}

extension VMOmarchyProfile {
    public static let production = VMOmarchyProfile(
        schemaVersion: currentSchemaVersion,
        productID: "com.everettjf.ezvm.omarchy",
        minimumHostMajorVersion: 27,
        diskCapacityBytes: 64 * 1_024 * 1_024 * 1_024,
        resourceTiers: [
            .init(hostMemoryBytes: 16 * 1_024 * 1_024 * 1_024, cpuCount: 4, memoryBytes: 8 * 1_024 * 1_024 * 1_024),
            .init(hostMemoryBytes: 24 * 1_024 * 1_024 * 1_024, cpuCount: 6, memoryBytes: 12 * 1_024 * 1_024 * 1_024),
            .init(hostMemoryBytes: 32 * 1_024 * 1_024 * 1_024, cpuCount: 6, memoryBytes: 16 * 1_024 * 1_024 * 1_024),
            .init(hostMemoryBytes: 64 * 1_024 * 1_024 * 1_024, cpuCount: 8, memoryBytes: 24 * 1_024 * 1_024 * 1_024),
        ],
        requiredGuestCapabilities: [
            "agent-restart-v1",
            "desktop-input-v1",
            "dynamic-display-v1",
            "shutdown-v1",
        ],
        factoryImage: .init(
            manifestURL: URL(string: "https://github.com/everettjf/omarchy-aarch64-image/releases/latest/download/ezvm-omarchy-factory-manifest.json")!,
            signingKeyID: "ezvm-omarchy-factory-2026",
            architecture: "arm64",
            maximumDownloadBytes: 8 * 1_024 * 1_024 * 1_024
        )
    )
}
