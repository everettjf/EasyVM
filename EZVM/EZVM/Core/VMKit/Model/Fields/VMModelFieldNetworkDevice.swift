import Foundation
import Virtualization
import vmnet
import Darwin
import CryptoKit

#if arch(arm64)
private let ezvmVMNetSuccess = vmnet_return_t.VMNET_SUCCESS
private let ezvmVMNetHostMode = vmnet_mode_t.VMNET_HOST_MODE
private let ezvmVMNetSharedMode = vmnet_mode_t.VMNET_SHARED_MODE

enum VMHostPortAvailability: Equatable {
    case available
    case occupied
    case unavailable(String)
}

enum VMHostPortProbe {
    static func availability(
        transport: VMModelFieldNetworkDevice.PortForwardingRule.Transport,
        port: UInt16
    ) -> VMHostPortAvailability {
        let socketType = transport == .tcp ? SOCK_STREAM : SOCK_DGRAM
        let descriptor = socket(AF_INET, socketType, 0)
        guard descriptor >= 0 else {
            return .unavailable(String(cString: strerror(errno)))
        }
        defer { close(descriptor) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: INADDR_ANY)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else {
            return errno == EADDRINUSE
                ? .occupied
                : .unavailable(String(cString: strerror(errno)))
        }
        return .available
    }
}

enum VMNetNamedNetworkOwnershipResult {
    case acquired(VMNetNamedNetworkLease)
    case alreadyOwned(signatureMatches: Bool)
    case unavailable(String)
}

final class VMNetNamedNetworkLease {
    fileprivate let identifier: String
    fileprivate let signature: String
    fileprivate let id = UUID()
    fileprivate let handle: FileHandle

    fileprivate init(identifier: String, signature: String, descriptor: Int32) {
        self.identifier = identifier
        self.signature = signature
        handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }
}

/// Prevents two EZVM processes from independently reserving the same named
/// VMNet topology. A `VZVmnetNetworkDeviceAttachment` must use a network
/// created in its own process, so safe cross-process reuse requires a future
/// XPC coordinator that transports Apple's serialized network object.
final class VMNetNamedNetworkOwnershipRegistry {
    private struct Record: Codable {
        let schemaVersion: Int
        let identifier: String
        let signature: String
        let pid: Int32
        let updatedAt: Date
    }

    private let directory: URL
    private let lock = NSLock()
    private var leases: [String: VMNetNamedNetworkLease] = [:]

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("EZVM/NetworkLeases", isDirectory: true)
    }

    func acquire(identifier: String, signature: String) -> VMNetNamedNetworkOwnershipResult {
        lock.lock()
        defer { lock.unlock() }

        if let lease = leases[identifier] {
            return .alreadyOwned(signatureMatches: lease.signature == signature)
        }
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            return .unavailable("EZVM could not prepare its network ownership directory: \(error.localizedDescription)")
        }

        let descriptor = open(lockURL(identifier: identifier).path, O_RDWR | O_CREAT | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            return .unavailable("EZVM could not open the network ownership lock: \(String(cString: strerror(errno))).")
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let lockError = errno
            close(descriptor)
            guard lockError == EWOULDBLOCK else {
                return .unavailable("EZVM could not check network ownership: \(String(cString: strerror(lockError))).")
            }
            let existingSignature = readRecord(identifier: identifier)?.signature
            return .alreadyOwned(signatureMatches: existingSignature == signature)
        }

        let lease = VMNetNamedNetworkLease(identifier: identifier, signature: signature, descriptor: descriptor)
        guard writeRecord(for: lease) else {
            flock(descriptor, LOCK_UN)
            try? lease.handle.close()
            return .unavailable("EZVM could not record ownership of VMNet network ‘\(identifier)’.")
        }
        leases[identifier] = lease
        return .acquired(lease)
    }

    func release(_ lease: VMNetNamedNetworkLease) {
        lock.lock()
        defer { lock.unlock() }
        guard leases[lease.identifier]?.id == lease.id else { return }
        leases.removeValue(forKey: lease.identifier)
        try? FileManager.default.removeItem(at: recordURL(identifier: lease.identifier))
        flock(lease.handle.fileDescriptor, LOCK_UN)
        try? lease.handle.close()
    }

    private func lockURL(identifier: String) -> URL {
        directory.appendingPathComponent("\(digest(identifier)).lock", isDirectory: false)
    }

    private func recordURL(identifier: String) -> URL {
        directory.appendingPathComponent("\(digest(identifier)).json", isDirectory: false)
    }

    private func digest(_ identifier: String) -> String {
        SHA256.hash(data: Data(identifier.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func readRecord(identifier: String) -> Record? {
        try? JSONDecoder().decode(Record.self, from: Data(contentsOf: recordURL(identifier: identifier)))
    }

    private func writeRecord(for lease: VMNetNamedNetworkLease) -> Bool {
        let record = Record(
            schemaVersion: 1,
            identifier: lease.identifier,
            signature: lease.signature,
            pid: getpid(),
            updatedAt: Date()
        )
        guard let data = try? JSONEncoder().encode(record) else { return false }
        let url = recordURL(identifier: lease.identifier)
        do {
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return true
        } catch {
            return false
        }
    }
}

private final class VMNetLogicalNetworkRegistry: @unchecked Sendable {
    enum Lookup {
        case missing
        case found(vmnet_network_ref)
        case conflictingConfiguration
    }

    private struct Entry {
        let signature: String
        let network: vmnet_network_ref
        let ownershipLease: VMNetNamedNetworkLease
    }

    static let shared = VMNetLogicalNetworkRegistry()
    private let lock = NSLock()
    private let ownership = VMNetNamedNetworkOwnershipRegistry()
    private var entries: [String: Entry] = [:]

    func lookup(identifier: String, signature: String) -> Lookup {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[identifier] else { return .missing }
        return entry.signature == signature ? .found(entry.network) : .conflictingConfiguration
    }

    func store(
        _ network: vmnet_network_ref,
        identifier: String,
        signature: String,
        ownershipLease: VMNetNamedNetworkLease
    ) {
        lock.lock()
        entries[identifier] = Entry(
            signature: signature,
            network: network,
            ownershipLease: ownershipLease
        )
        lock.unlock()
    }

    func acquireOwnership(identifier: String, signature: String) -> VMNetNamedNetworkOwnershipResult {
        ownership.acquire(identifier: identifier, signature: signature)
    }

    func releaseOwnership(_ lease: VMNetNamedNetworkLease) {
        ownership.release(lease)
    }
}

struct VMModelFieldNetworkDevice: Codable, CustomStringConvertible {
    private static let vmnetCreationLock = NSLock()

    struct PortForwardingRule: Codable, Equatable, Identifiable {
        enum Transport: String, Codable, CaseIterable, Identifiable {
            case tcp, udp
            var id: Self { self }
            var displayName: String { rawValue.uppercased() }
        }

        let id: UUID
        let transport: Transport
        let externalPort: UInt16
        let internalAddress: String
        let internalPort: UInt16

        init(
            id: UUID = UUID(),
            transport: Transport,
            externalPort: UInt16,
            internalAddress: String,
            internalPort: UInt16
        ) {
            self.id = id
            self.transport = transport
            self.externalPort = externalPort
            self.internalAddress = internalAddress.trimmingCharacters(in: .whitespacesAndNewlines)
            self.internalPort = internalPort
        }
    }

    enum DeviceType: String, CaseIterable, Identifiable, Codable {
        case NAT, VMNetShared, VMNetHost, FileHandle

        var id: Self { self }
        static var userSelectableCases: [Self] { [.NAT, .VMNetShared, .VMNetHost] }

        var displayName: String {
            switch self {
            case .NAT: "NAT (compatible default)"
            case .VMNetShared: "VMNet Shared"
            case .VMNetHost: "VMNet Host-only"
            case .FileHandle: "Legacy FileHandle"
            }
        }

        var shortDisplayName: String {
            switch self {
            case .NAT: "NAT"
            case .VMNetShared: "Shared Network"
            case .VMNetHost: "Host-only"
            case .FileHandle: "Legacy FileHandle"
            }
        }

        var outcomeDescription: String {
            switch self {
            case .NAT: "Simple internet access through this Mac. Best for most virtual machines."
            case .VMNetShared: "Internet access plus a reusable VMNet network for host access and port forwarding."
            case .VMNetHost: "A private VMNet network between this Mac and participating virtual machines, without internet access."
            case .FileHandle: "A legacy file-descriptor connection that cannot be restored from saved configuration."
            }
        }

        var reachabilitySummary: String {
            switch self {
            case .NAT: "Guest → Internet"
            case .VMNetShared: "Guest → Internet · Mac ↔ Guest"
            case .VMNetHost: "Mac ↔ Guest · VM ↔ VM"
            case .FileHandle: "Custom endpoint"
            }
        }

        var symbolName: String {
            switch self {
            case .NAT: "network"
            case .VMNetShared: "point.3.connected.trianglepath.dotted"
            case .VMNetHost: "lock.shield"
            case .FileHandle: "cable.connector"
            }
        }

        var usesVMNet: Bool { self == .VMNetShared || self == .VMNetHost }
    }

    let type: DeviceType
    let networkIdentifier: String?
    let ipv4Subnet: String?
    let ipv4SubnetMask: String?
    let externalInterface: String?
    let mtu: UInt32?
    let portForwardingRules: [PortForwardingRule]

    init(
        type: DeviceType,
        networkIdentifier: String? = nil,
        ipv4Subnet: String? = nil,
        ipv4SubnetMask: String? = nil,
        externalInterface: String? = nil,
        mtu: UInt32? = nil,
        portForwardingRules: [PortForwardingRule] = []
    ) {
        self.type = type
        self.networkIdentifier = networkIdentifier?.nilIfTrimmedEmpty
        self.ipv4Subnet = ipv4Subnet?.nilIfTrimmedEmpty
        self.ipv4SubnetMask = ipv4SubnetMask?.nilIfTrimmedEmpty
        self.externalInterface = externalInterface?.nilIfTrimmedEmpty
        self.mtu = mtu
        self.portForwardingRules = portForwardingRules
    }

    private enum CodingKeys: String, CodingKey {
        case type, networkIdentifier, ipv4Subnet, ipv4SubnetMask, externalInterface, mtu, portForwardingRules
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let savedType = try container.decodeIfPresent(String.self, forKey: .type) ?? DeviceType.NAT.rawValue
        // Experimental builds could save bridged or vmnet-backed modes.
        // Existing machines fall back to ordinary NAT networking.
        type = DeviceType(rawValue: savedType) ?? .NAT
        networkIdentifier = try container.decodeIfPresent(String.self, forKey: .networkIdentifier)?.nilIfTrimmedEmpty
        ipv4Subnet = try container.decodeIfPresent(String.self, forKey: .ipv4Subnet)?.nilIfTrimmedEmpty
        ipv4SubnetMask = try container.decodeIfPresent(String.self, forKey: .ipv4SubnetMask)?.nilIfTrimmedEmpty
        externalInterface = try container.decodeIfPresent(String.self, forKey: .externalInterface)?.nilIfTrimmedEmpty
        mtu = try container.decodeIfPresent(UInt32.self, forKey: .mtu)
        portForwardingRules = try container.decodeIfPresent(
            [PortForwardingRule].self,
            forKey: .portForwardingRules
        ) ?? []
    }

    var description: String {
        guard type == .VMNetShared || type == .VMNetHost else { return type.displayName }
        return "\(type.displayName) · \(networkIdentifier ?? "isolated")"
    }

    var configurationSummary: String {
        guard type.usesVMNet else { return "Automatic addressing and routing" }
        var details = [networkIdentifier.map { "Network \($0)" } ?? "macOS-managed network"]
        if let ipv4Subnet, let ipv4SubnetMask {
            details.append("\(ipv4Subnet) / \(ipv4SubnetMask)")
        }
        if let mtu { details.append("MTU \(mtu)") }
        if type == .VMNetShared, !portForwardingRules.isEmpty {
            details.append("\(portForwardingRules.count) port rule\(portForwardingRules.count == 1 ? "" : "s")")
        }
        return details.joined(separator: " · ")
    }

    static func `default`() -> VMModelFieldNetworkDevice {
        VMModelFieldNetworkDevice(type: .NAT)
    }

    static func createConfigurations(_ models: [VMModelFieldNetworkDevice]) -> VMOSResult<[VZNetworkDeviceConfiguration], String> {
        if let error = collectionValidationError(
            models,
            vmnetEntitlementGranted: VMHostCapability.vmnet.isGranted,
            availableInterfaceNames: hostInterfaceNames(),
            hostPortAvailability: VMHostPortProbe.availability
        ) {
            return .failure(error)
        }
        var configurations: [VZNetworkDeviceConfiguration] = []
        for model in models {
            switch model.createConfiguration() {
            case .success(let configuration): configurations.append(configuration)
            case .failure(let error): return .failure(error)
            }
        }
        return .success(configurations)
    }

    static func collectionValidationError(
        _ models: [VMModelFieldNetworkDevice],
        vmnetEntitlementGranted: Bool,
        availableInterfaceNames: Set<String>? = nil,
        hostPortAvailability: ((PortForwardingRule.Transport, UInt16) -> VMHostPortAvailability)? = nil
    ) -> String? {
        var networkSignatures: [String: String] = [:]
        var externalEndpointOwners: [String: String] = [:]
        var externalEndpoints: [String: (PortForwardingRule.Transport, UInt16)] = [:]
        var ownersAlreadyActive = Set<String>()
        var configuredSubnets: [(owner: String, first: UInt32, last: UInt32, description: String)] = []

        for (index, model) in models.enumerated() {
            if let error = model.validationError(
                vmnetEntitlementGranted: vmnetEntitlementGranted,
                availableInterfaceNames: availableInterfaceNames
            ) {
                return error
            }
            if let identifier = model.networkIdentifier,
               model.type == .VMNetShared || model.type == .VMNetHost {
                if let existing = networkSignatures[identifier],
                   existing != model.vmnetConfigurationSignature {
                    return "VMNet network ‘\(identifier)’ is configured more than once with different settings."
                }
                networkSignatures[identifier] = model.vmnetConfigurationSignature
            }
            guard model.type == .VMNetShared || model.type == .VMNetHost else { continue }
            let networkOwner = model.networkIdentifier.map {
                "named:\($0):\(model.vmnetConfigurationSignature)"
            } ?? "anonymous:\(index)"
            if let subnetText = model.ipv4Subnet,
               let maskText = model.ipv4SubnetMask,
               let subnet = ipv4Value(subnetText),
               let mask = ipv4Value(maskText) {
                let first = subnet & mask
                let last = first | ~mask
                if let overlap = configuredSubnets.first(where: {
                    $0.owner != networkOwner && first <= $0.last && $0.first <= last
                }) {
                    return "VMNet subnet \(subnetText)/\(maskText) overlaps \(overlap.description). Choose non-overlapping subnets for different logical networks."
                }
                configuredSubnets.append((
                    owner: networkOwner,
                    first: first,
                    last: last,
                    description: "\(subnetText)/\(maskText)"
                ))
            }
            guard model.type == .VMNetShared else { continue }
            if let identifier = model.networkIdentifier,
               case .found = VMNetLogicalNetworkRegistry.shared.lookup(
                   identifier: identifier,
                   signature: model.vmnetConfigurationSignature
               ) {
                ownersAlreadyActive.insert(networkOwner)
            }
            for rule in model.portForwardingRules {
                let endpoint = "\(rule.transport.rawValue):\(rule.externalPort)"
                if let existingOwner = externalEndpointOwners[endpoint],
                   existingOwner != networkOwner {
                    return "External \(rule.transport.displayName) port \(rule.externalPort) is forwarded more than once in this virtual machine."
                }
                externalEndpointOwners[endpoint] = networkOwner
                externalEndpoints[endpoint] = (rule.transport, rule.externalPort)
            }
        }
        if let hostPortAvailability {
            for endpoint in externalEndpoints.keys.sorted() {
                guard let owner = externalEndpointOwners[endpoint],
                      !ownersAlreadyActive.contains(owner),
                      let (transport, port) = externalEndpoints[endpoint] else { continue }
                switch hostPortAvailability(transport, port) {
                case .available:
                    break
                case .occupied:
                    return "External \(transport.displayName) port \(port) is already in use on this Mac. Choose another external port or stop the process using it."
                case .unavailable(let detail):
                    return "EZVM could not verify external \(transport.displayName) port \(port): \(detail). Choose another port or check local network permissions."
                }
            }
        }
        return nil
    }

    var validationError: String? {
        validationError(vmnetEntitlementGranted: VMHostCapability.vmnet.isGranted)
    }

    func validationError(vmnetEntitlementGranted: Bool) -> String? {
        validationError(vmnetEntitlementGranted: vmnetEntitlementGranted, availableInterfaceNames: nil)
    }

    func validationError(
        vmnetEntitlementGranted: Bool,
        availableInterfaceNames: Set<String>?
    ) -> String? {
        guard type == .VMNetShared || type == .VMNetHost else { return nil }
        if !vmnetEntitlementGranted {
            return "The signed EZVM app does not have the VMNet entitlement."
        }
        if let networkIdentifier,
           networkIdentifier.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$"#, options: .regularExpression) == nil {
            return "The VMNet network name must be 1–64 letters, numbers, dots, underscores, or hyphens."
        }
        if (ipv4Subnet == nil) != (ipv4SubnetMask == nil) {
            return "Set both the IPv4 subnet and subnet mask, or leave both blank."
        }
        if let ipv4Subnet, Self.parseIPv4(ipv4Subnet) == nil {
            return "The VMNet IPv4 subnet is not a valid IPv4 address."
        }
        if let ipv4SubnetMask {
            guard let mask = Self.ipv4Value(ipv4SubnetMask) else {
                return "The VMNet subnet mask is not a valid IPv4 address."
            }
            guard Self.isContiguousSubnetMask(mask) else {
                return "The VMNet subnet mask must contain contiguous network bits, such as 255.255.255.0."
            }
        }
        if let ipv4Subnet, let ipv4SubnetMask,
           let subnet = Self.ipv4Value(ipv4Subnet),
           let mask = Self.ipv4Value(ipv4SubnetMask),
           subnet != subnet & mask {
            return "The VMNet subnet must be a network address. For this mask, use \(Self.ipv4String(subnet & mask))."
        }
        if type == .VMNetHost, externalInterface != nil {
            return "An external interface can only be selected for VMNet Shared mode."
        }
        if let externalInterface, let availableInterfaceNames,
           !availableInterfaceNames.contains(externalInterface) {
            return "The VMNet external interface ‘\(externalInterface)’ is not available on this Mac. Choose a connected interface or use Automatic."
        }
        if type != .VMNetShared, !portForwardingRules.isEmpty {
            return "Port forwarding is only available for VMNet Shared mode."
        }
        var externalEndpoints = Set<String>()
        for rule in portForwardingRules {
            guard rule.externalPort != 0, rule.internalPort != 0 else {
                return "VMNet port-forwarding ports must be between 1 and 65535."
            }
            guard Self.parseIPv4(rule.internalAddress) != nil else {
                return "A VMNet port-forwarding destination is not a valid IPv4 address."
            }
            if let ipv4Subnet, let ipv4SubnetMask,
               let subnet = Self.ipv4Value(ipv4Subnet),
               let mask = Self.ipv4Value(ipv4SubnetMask),
               let destination = Self.ipv4Value(rule.internalAddress) {
                let broadcast = (subnet & mask) | ~mask
                guard destination & mask == subnet & mask,
                      destination != subnet & mask,
                      destination != broadcast else {
                    return "VMNet forwarding destination \(rule.internalAddress) must be a usable address inside \(ipv4Subnet)/\(ipv4SubnetMask)."
                }
            }
            let endpoint = "\(rule.transport.rawValue):\(rule.externalPort)"
            guard externalEndpoints.insert(endpoint).inserted else {
                return "Each VMNet external TCP or UDP port can only be forwarded once."
            }
        }
        if let mtu, !(576...9000).contains(mtu) {
            return "VMNet MTU must be between 576 and 9000."
        }
        return nil
    }

    func createConfiguration() -> VMOSResult<VZNetworkDeviceConfiguration, String> {
        let device = VZVirtioNetworkDeviceConfiguration()
        switch type {
        case .NAT:
            device.attachment = VZNATNetworkDeviceAttachment()
        case .VMNetShared, .VMNetHost:
            // Lookup, cross-process ownership, and creation are one process-local
            // critical section. Otherwise two simultaneous VM starts could both
            // observe a missing entry and misreport the second as another process.
            Self.vmnetCreationLock.lock()
            defer { Self.vmnetCreationLock.unlock() }
            if let validationError { return .failure(validationError) }
            let networkSignature = vmnetConfigurationSignature
            if let networkIdentifier {
                switch VMNetLogicalNetworkRegistry.shared.lookup(
                    identifier: networkIdentifier,
                    signature: networkSignature
                ) {
                case .found(let network):
                    device.attachment = VZVmnetNetworkDeviceAttachment(network: network)
                    return .success(device)
                case .conflictingConfiguration:
                    return .failure("VMNet network ‘\(networkIdentifier)’ is already active with different settings.")
                case .missing:
                    break
                }
            }
            var status = ezvmVMNetSuccess
            let mode = type == .VMNetShared ? ezvmVMNetSharedMode : ezvmVMNetHostMode
            guard let networkConfiguration = vmnet_network_configuration_create(mode, &status) else {
                return .failure("Could not create the VMNet configuration (status \(status.rawValue)).")
            }

            if let externalInterface {
                let result = externalInterface.withCString {
                    vmnet_network_configuration_set_external_interface(networkConfiguration, $0)
                }
                guard result == ezvmVMNetSuccess else {
                    return .failure("Could not select VMNet interface \(externalInterface) (status \(result.rawValue)).")
                }
            }
            if let ipv4Subnet, let ipv4SubnetMask,
               var subnet = Self.parseIPv4(ipv4Subnet),
               var mask = Self.parseIPv4(ipv4SubnetMask) {
                let result = vmnet_network_configuration_set_ipv4_subnet(networkConfiguration, &subnet, &mask)
                guard result == ezvmVMNetSuccess else {
                    return .failure("Could not configure the VMNet IPv4 subnet (status \(result.rawValue)).")
                }
            }
            if let mtu {
                let result = vmnet_network_configuration_set_mtu(networkConfiguration, mtu)
                guard result == ezvmVMNetSuccess else {
                    return .failure("Could not configure the VMNet MTU (status \(result.rawValue)).")
                }
            }
            for rule in portForwardingRules {
                guard var address = Self.parseIPv4(rule.internalAddress) else {
                    return .failure("Invalid VMNet port-forwarding destination: \(rule.internalAddress).")
                }
                let transport = rule.transport == .tcp ? UInt8(IPPROTO_TCP) : UInt8(IPPROTO_UDP)
                let result = withUnsafePointer(to: &address) {
                    vmnet_network_configuration_add_port_forwarding_rule(
                        networkConfiguration,
                        transport,
                        sa_family_t(AF_INET),
                        rule.internalPort,
                        rule.externalPort,
                        $0
                    )
                }
                guard result == ezvmVMNetSuccess else {
                    return .failure("Could not add the VMNet \(rule.transport.displayName) port-forwarding rule (status \(result.rawValue)).")
                }
            }

            var ownershipLease: VMNetNamedNetworkLease?
            if let networkIdentifier {
                switch VMNetLogicalNetworkRegistry.shared.acquireOwnership(
                    identifier: networkIdentifier,
                    signature: networkSignature
                ) {
                case .acquired(let lease):
                    ownershipLease = lease
                case .alreadyOwned(let signatureMatches):
                    return .failure(
                        signatureMatches
                            ? "VMNet network ‘\(networkIdentifier)’ is active in another EZVM process. Stop the virtual machine using it or close that EZVM process, then try again."
                            : "VMNet network ‘\(networkIdentifier)’ is active in another EZVM process with different settings. Choose another network name or close that EZVM process."
                    )
                case .unavailable(let error):
                    return .failure(error)
                }
            }

            guard let network = vmnet_network_create(networkConfiguration, &status) else {
                if let ownershipLease {
                    VMNetLogicalNetworkRegistry.shared.releaseOwnership(ownershipLease)
                }
                return .failure("Could not reserve the VMNet logical network (status \(status.rawValue)).")
            }
            if let networkIdentifier, let ownershipLease {
                VMNetLogicalNetworkRegistry.shared.store(
                    network,
                    identifier: networkIdentifier,
                    signature: networkSignature,
                    ownershipLease: ownershipLease
                )
            }
            device.attachment = VZVmnetNetworkDeviceAttachment(network: network)
        case .FileHandle:
            return .failure("Legacy FileHandle networking requires a live file descriptor and can no longer be configured from a saved VM.")
        }
        return .success(device)
    }

    private static func parseIPv4(_ value: String) -> in_addr? {
        var address = in_addr()
        return value.withCString { inet_pton(AF_INET, $0, &address) == 1 ? address : nil }
    }

    private static func ipv4Value(_ value: String) -> UInt32? {
        parseIPv4(value).map { UInt32(bigEndian: $0.s_addr) }
    }

    private static func ipv4String(_ value: UInt32) -> String {
        "\((value >> 24) & 0xFF).\((value >> 16) & 0xFF).\((value >> 8) & 0xFF).\(value & 0xFF)"
    }

    private static func isContiguousSubnetMask(_ mask: UInt32) -> Bool {
        guard mask != 0 else { return false }
        let inverted = ~mask
        return inverted & (inverted &+ 1) == 0
    }

    private static func hostInterfaceNames() -> Set<String>? {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let first = interfaces else { return nil }
        defer { freeifaddrs(interfaces) }
        var names = Set<String>()
        var current: UnsafeMutablePointer<ifaddrs>? = first
        while let interface = current {
            names.insert(String(cString: interface.pointee.ifa_name))
            current = interface.pointee.ifa_next
        }
        return names
    }

    private var vmnetConfigurationSignature: String {
        let rules = portForwardingRules.map {
            "\($0.transport.rawValue):\($0.externalPort):\($0.internalAddress):\($0.internalPort)"
        }.sorted().joined(separator: ",")
        return [
            type.rawValue,
            ipv4Subnet ?? "",
            ipv4SubnetMask ?? "",
            externalInterface ?? "",
            mtu.map(String.init) ?? "",
            rules,
        ].joined(separator: "|")
    }
}

struct VMNetworkDeviceDraft: Equatable {
    var type: VMModelFieldNetworkDevice.DeviceType = .NAT
    var networkIdentifier = ""
    var ipv4Subnet = ""
    var ipv4SubnetMask = ""
    var externalInterface = ""
    var mtu = "1500"
    var portForwardingRules: [VMModelFieldNetworkDevice.PortForwardingRule] = []

    func build(vmnetEntitlementGranted: Bool = VMHostCapability.vmnet.isGranted) -> VMOSResult<VMModelFieldNetworkDevice, String> {
        if type == .NAT {
            return .success(VMModelFieldNetworkDevice(type: .NAT))
        }
        guard let mtuValue = UInt32(mtu.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return .failure("MTU must be a whole number between 576 and 9000.")
        }
        let model = VMModelFieldNetworkDevice(
            type: type,
            networkIdentifier: networkIdentifier,
            ipv4Subnet: ipv4Subnet,
            ipv4SubnetMask: ipv4SubnetMask,
            externalInterface: type == .VMNetShared ? externalInterface : nil,
            mtu: mtuValue,
            portForwardingRules: type == .VMNetShared ? portForwardingRules : []
        )
        if let error = model.validationError(vmnetEntitlementGranted: vmnetEntitlementGranted) {
            return .failure(error)
        }
        return .success(model)
    }
}

private extension String {
    var nilIfTrimmedEmpty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
#endif
