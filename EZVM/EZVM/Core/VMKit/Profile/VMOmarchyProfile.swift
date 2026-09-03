import Foundation

/// Versioned product contract shared by EZVM and the dedicated EZVM Omarchy app.
/// It deliberately contains product policy, not mutable per-workspace state.
struct VMOmarchyProfile: Codable, Equatable {
    static let currentSchemaVersion = 1

    struct ResourceTier: Codable, Equatable {
        let hostMemoryBytes: UInt64
        let cpuCount: Int
        let memoryBytes: UInt64
    }

    struct FactoryImage: Codable, Equatable {
        let manifestURL: URL
        let signingKeyID: String
        let architecture: String
        let maximumDownloadBytes: UInt64
    }

    let schemaVersion: Int
    let productID: String
    let minimumHostMajorVersion: Int
    let diskCapacityBytes: UInt64
    let resourceTiers: [ResourceTier]
    let requiredGuestCapabilities: [String]
    let factoryImage: FactoryImage

    func validate() throws {
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

    func resources(forHostMemory hostMemoryBytes: UInt64, activeProcessorCount: Int) -> ResourceTier {
        let selected = resourceTiers.last(where: { hostMemoryBytes >= $0.hostMemoryBytes })
            ?? resourceTiers[0]
        return ResourceTier(
            hostMemoryBytes: selected.hostMemoryBytes,
            cpuCount: min(selected.cpuCount, max(2, activeProcessorCount - 2)),
            memoryBytes: min(selected.memoryBytes, hostMemoryBytes / 2)
        )
    }

    enum ValidationError: Error, Equatable {
        case unsupportedSchema(Int)
        case invalidProductID
        case invalidPlatformPolicy
        case invalidResourcePolicy
        case invalidFactoryImage
        case invalidCapabilities
    }
}

extension VMOmarchyProfile {
    static let production = VMOmarchyProfile(
        schemaVersion: currentSchemaVersion,
        productID: "com.everettjf.ezvm.omarchy",
        minimumHostMajorVersion: 27,
        diskCapacityBytes: 128 * 1_024 * 1_024 * 1_024,
        resourceTiers: [
            .init(hostMemoryBytes: 16 * 1_024 * 1_024 * 1_024, cpuCount: 4, memoryBytes: 8 * 1_024 * 1_024 * 1_024),
            .init(hostMemoryBytes: 24 * 1_024 * 1_024 * 1_024, cpuCount: 6, memoryBytes: 12 * 1_024 * 1_024 * 1_024),
            .init(hostMemoryBytes: 32 * 1_024 * 1_024 * 1_024, cpuCount: 6, memoryBytes: 16 * 1_024 * 1_024 * 1_024),
            .init(hostMemoryBytes: 64 * 1_024 * 1_024 * 1_024, cpuCount: 8, memoryBytes: 24 * 1_024 * 1_024 * 1_024),
        ],
        requiredGuestCapabilities: [
            "desktop-input-v1",
            "dynamic-display-v1",
            "shutdown-v1",
        ],
        factoryImage: .init(
            manifestURL: URL(string: "https://download.ezvm.app/omarchy/stable/manifest.json")!,
            signingKeyID: "ezvm-omarchy-factory-2026",
            architecture: "arm64",
            maximumDownloadBytes: 32 * 1_024 * 1_024 * 1_024
        )
    )
}
