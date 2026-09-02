import Foundation
import Virtualization
import vmnet
import Darwin

#if arch(arm64)
private let ezvmVMNetSuccess = vmnet_return_t(rawValue: 1000)!
private let ezvmVMNetHostMode = vmnet_mode_t(rawValue: 1000)!
private let ezvmVMNetSharedMode = vmnet_mode_t(rawValue: 1001)!

private final class VMNetLogicalNetworkRegistry: @unchecked Sendable {
    enum Lookup {
        case missing
        case found(vmnet_network_ref)
        case conflictingConfiguration
    }

    private struct Entry {
        let signature: String
        let network: vmnet_network_ref
    }

    static let shared = VMNetLogicalNetworkRegistry()
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    func lookup(identifier: String, signature: String) -> Lookup {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[identifier] else { return .missing }
        return entry.signature == signature ? .found(entry.network) : .conflictingConfiguration
    }

    func store(_ network: vmnet_network_ref, identifier: String, signature: String) {
        lock.lock()
        entries[identifier] = Entry(signature: signature, network: network)
        lock.unlock()
    }
}

struct VMModelFieldNetworkDevice: Codable, CustomStringConvertible {
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

    static func `default`() -> VMModelFieldNetworkDevice {
        VMModelFieldNetworkDevice(type: .NAT)
    }

    static func createConfigurations(_ models: [VMModelFieldNetworkDevice]) -> VMOSResult<[VZNetworkDeviceConfiguration], String> {
        var configurations: [VZNetworkDeviceConfiguration] = []
        for model in models {
            switch model.createConfiguration() {
            case .success(let configuration): configurations.append(configuration)
            case .failure(let error): return .failure(error)
            }
        }
        return .success(configurations)
    }

    var validationError: String? {
        validationError(vmnetEntitlementGranted: VMHostCapability.vmnet.isGranted)
    }

    func validationError(vmnetEntitlementGranted: Bool) -> String? {
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
        if let ipv4SubnetMask, Self.parseIPv4(ipv4SubnetMask) == nil {
            return "The VMNet subnet mask is not a valid IPv4 address."
        }
        if type == .VMNetHost, externalInterface != nil {
            return "An external interface can only be selected for VMNet Shared mode."
        }
        if type != .VMNetShared, !portForwardingRules.isEmpty {
            return "Port forwarding is only available for VMNet Shared mode."
        }
        var externalEndpoints = Set<String>()
        for rule in portForwardingRules {
            guard Self.parseIPv4(rule.internalAddress) != nil else {
                return "A VMNet port-forwarding destination is not a valid IPv4 address."
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

            guard let network = vmnet_network_create(networkConfiguration, &status) else {
                return .failure("Could not reserve the VMNet logical network (status \(status.rawValue)).")
            }
            if let networkIdentifier {
                VMNetLogicalNetworkRegistry.shared.store(
                    network,
                    identifier: networkIdentifier,
                    signature: networkSignature
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

private extension String {
    var nilIfTrimmedEmpty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
#endif
