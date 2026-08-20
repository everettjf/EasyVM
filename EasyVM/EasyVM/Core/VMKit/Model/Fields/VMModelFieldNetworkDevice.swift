import Darwin
import Foundation
import Virtualization
import vmnet

#if arch(arm64)
struct VMPortForwardingRule: Codable, Equatable, Identifiable {
    enum Transport: String, Codable, CaseIterable, Identifiable {
        case tcp, udp
        var id: String { rawValue }
    }

    var id: UUID
    var transport: Transport
    var hostPort: UInt16
    var guestAddress: String
    var guestPort: UInt16

    init(id: UUID = UUID(), transport: Transport = .tcp, hostPort: UInt16 = 2222, guestAddress: String = "192.168.105.2", guestPort: UInt16 = 22) {
        self.id = id
        self.transport = transport
        self.hostPort = hostPort
        self.guestAddress = guestAddress
        self.guestPort = guestPort
    }
}

struct VMModelFieldNetworkDevice: Codable, CustomStringConvertible {
    enum DeviceType: String, CaseIterable, Identifiable, Codable {
        case NAT, Bridged, HostOnly, Custom, FileHandle
        var id: Self { self }
        static var userSelectableCases: [Self] { [.NAT, .Bridged, .HostOnly, .Custom] }
    }

    let type: DeviceType
    let networkIdentifier: String
    let bridgedInterfaceIdentifier: String?
    let externalInterfaceName: String?
    let subnetAddress: String
    let subnetMask: String
    let mtu: UInt32
    let portForwardingRules: [VMPortForwardingRule]

    init(
        type: DeviceType,
        networkIdentifier: String = "easyvm-default",
        bridgedInterfaceIdentifier: String? = nil,
        externalInterfaceName: String? = nil,
        subnetAddress: String = "192.168.105.0",
        subnetMask: String = "255.255.255.0",
        mtu: UInt32 = 1500,
        portForwardingRules: [VMPortForwardingRule] = []
    ) {
        self.type = type
        self.networkIdentifier = networkIdentifier
        self.bridgedInterfaceIdentifier = bridgedInterfaceIdentifier
        self.externalInterfaceName = externalInterfaceName
        self.subnetAddress = subnetAddress
        self.subnetMask = subnetMask
        self.mtu = mtu
        self.portForwardingRules = portForwardingRules
    }

    private enum CodingKeys: String, CodingKey {
        case type, networkIdentifier, bridgedInterfaceIdentifier, externalInterfaceName
        case subnetAddress, subnetMask, mtu, portForwardingRules
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(DeviceType.self, forKey: .type)
        networkIdentifier = try container.decodeIfPresent(String.self, forKey: .networkIdentifier) ?? "easyvm-default"
        bridgedInterfaceIdentifier = try container.decodeIfPresent(String.self, forKey: .bridgedInterfaceIdentifier)
        externalInterfaceName = try container.decodeIfPresent(String.self, forKey: .externalInterfaceName)
        subnetAddress = try container.decodeIfPresent(String.self, forKey: .subnetAddress) ?? "192.168.105.0"
        subnetMask = try container.decodeIfPresent(String.self, forKey: .subnetMask) ?? "255.255.255.0"
        mtu = try container.decodeIfPresent(UInt32.self, forKey: .mtu) ?? 1500
        portForwardingRules = try container.decodeIfPresent([VMPortForwardingRule].self, forKey: .portForwardingRules) ?? []
    }

    var description: String {
        var detail = type.rawValue
        if type == .Bridged, let bridgedInterfaceIdentifier { detail += " · \(bridgedInterfaceIdentifier)" }
        if type == .HostOnly || type == .Custom { detail += " · \(networkIdentifier)" }
        if !portForwardingRules.isEmpty { detail += " · \(portForwardingRules.count) forwards" }
        return detail
    }

    static func `default`() -> VMModelFieldNetworkDevice { VMModelFieldNetworkDevice(type: .NAT) }

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
        if type == .Bridged, bridgedInterfaceIdentifier?.isEmpty != false {
            return "Choose a host interface for bridged networking."
        }

        let usesLogicalNetwork = type == .HostOnly || type == .Custom || (type == .NAT && !portForwardingRules.isEmpty)
        if usesLogicalNetwork, networkIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Enter a logical network name."
        }
        if usesLogicalNetwork, !(576...9000).contains(mtu) {
            return "MTU must be between 576 and 9000."
        }

        if type == .Custom || !portForwardingRules.isEmpty {
            guard let subnet = Self.ipv4Value(subnetAddress), let mask = Self.ipv4Value(subnetMask) else {
                return "Enter a valid IPv4 subnet and mask."
            }
            let invertedMask = ~mask
            guard mask != 0, (invertedMask & (invertedMask &+ 1)) == 0 else {
                return "The IPv4 subnet mask must contain contiguous network bits."
            }
            guard subnet & mask == subnet else {
                return "The IPv4 subnet address must not contain host bits."
            }

            var occupiedHostPorts = Set<String>()
            for rule in portForwardingRules {
                guard rule.hostPort != 0, rule.guestPort != 0 else {
                    return "Port forwarding ports must be between 1 and 65535."
                }
                guard let guest = Self.ipv4Value(rule.guestAddress), guest & mask == subnet else {
                    return "Guest address \(rule.guestAddress) is outside the configured subnet."
                }
                let broadcast = subnet | invertedMask
                guard guest != subnet, guest != broadcast else {
                    return "Guest address \(rule.guestAddress) cannot be the network or broadcast address."
                }
                let hostKey = "\(rule.transport.rawValue):\(rule.hostPort)"
                guard occupiedHostPorts.insert(hostKey).inserted else {
                    return "Host \(rule.transport.rawValue.uppercased()) port \(rule.hostPort) is forwarded more than once."
                }
            }
        }
        return nil
    }

    func createConfiguration() -> VMOSResult<VZNetworkDeviceConfiguration, String> {
        if let validationError { return .failure(validationError) }
        let device = VZVirtioNetworkDeviceConfiguration()
        switch type {
        case .NAT where portForwardingRules.isEmpty:
            device.attachment = VZNATNetworkDeviceAttachment()
        case .Bridged:
            let interfaces = VZBridgedNetworkInterface.networkInterfaces
            guard let interface = bridgedInterfaceIdentifier.flatMap({ id in interfaces.first { $0.identifier == id } }) ?? interfaces.first else {
                return .failure("No bridged network interface is available on this Mac.")
            }
            device.attachment = VZBridgedNetworkDeviceAttachment(interface: interface)
        case .NAT, .HostOnly, .Custom:
            guard #available(macOS 26.0, *) else {
                return .failure("Host-only, custom networking, and port forwarding require macOS 26 or later.")
            }
            switch VMNetLogicalNetworkRegistry.attachment(for: self) {
            case .success(let attachment): device.attachment = attachment
            case .failure(let error): return .failure(error)
            }
        case .FileHandle:
            return .failure("Legacy FileHandle networking requires a live file descriptor and can no longer be configured from a saved VM.")
        }
        return .success(device)
    }

    private static func ipv4Value(_ string: String) -> UInt32? {
        var address = in_addr()
        guard inet_pton(AF_INET, string, &address) == 1 else { return nil }
        return UInt32(bigEndian: address.s_addr)
    }
}

@available(macOS 26.0, *)
private enum VMNetLogicalNetworkRegistry {
    private struct Entry {
        let signature: String
        let network: vmnet_network_ref
    }

    private static let lock = NSLock()
    private static var networks: [String: Entry] = [:]
    private static let successStatus = vmnet_return_t(rawValue: 1000)!
    private static let hostMode = vmnet_mode_t(rawValue: 1000)!
    private static let sharedMode = vmnet_mode_t(rawValue: 1001)!

    static func attachment(for model: VMModelFieldNetworkDevice) -> VMOSResult<VZVmnetNetworkDeviceAttachment, String> {
        lock.lock()
        defer { lock.unlock() }

        let key = registryKey(for: model)
        let signature = configurationSignature(for: model)
        if let entry = networks[key] {
            guard entry.signature == signature else {
                return .failure("Logical network \(model.networkIdentifier) is already active with different settings. Use another network name or match its configuration.")
            }
            return .success(VZVmnetNetworkDeviceAttachment(network: entry.network))
        }

        var status = successStatus
        let mode: vmnet_mode_t = model.type == .HostOnly ? hostMode : sharedMode
        guard let configuration = vmnet_network_configuration_create(mode, &status) else {
            return .failure("Could not create vmnet configuration (status \(status.rawValue)).")
        }
        defer { Unmanaged<AnyObject>.fromOpaque(UnsafeRawPointer(configuration)).release() }

        if model.type == .Custom || !model.portForwardingRules.isEmpty {
            var subnet = in_addr()
            var mask = in_addr()
            guard inet_pton(AF_INET, model.subnetAddress, &subnet) == 1,
                  inet_pton(AF_INET, model.subnetMask, &mask) == 1 else {
                return .failure("The custom IPv4 subnet or mask is invalid.")
            }
            status = vmnet_network_configuration_set_ipv4_subnet(configuration, &subnet, &mask)
            guard status == successStatus else {
                return .failure("vmnet rejected the IPv4 subnet (status \(status.rawValue)).")
            }
        }

        if let external = model.externalInterfaceName, !external.isEmpty, model.type != .HostOnly {
            status = vmnet_network_configuration_set_external_interface(configuration, external)
            guard status == successStatus else {
                return .failure("vmnet rejected external interface \(external) (status \(status.rawValue)).")
            }
        }

        status = vmnet_network_configuration_set_mtu(configuration, model.mtu)
        guard status == successStatus else {
            return .failure("vmnet rejected MTU \(model.mtu) (status \(status.rawValue)).")
        }

        for rule in model.portForwardingRules {
            var guestAddress = in_addr()
            guard inet_pton(AF_INET, rule.guestAddress, &guestAddress) == 1 else {
                return .failure("Invalid guest address in port forwarding rule: \(rule.guestAddress)")
            }
            let transport = rule.transport == .tcp ? UInt8(IPPROTO_TCP) : UInt8(IPPROTO_UDP)
            status = vmnet_network_configuration_add_port_forwarding_rule(
                configuration, transport, sa_family_t(AF_INET), rule.guestPort, rule.hostPort, &guestAddress
            )
            guard status == successStatus else {
                return .failure("Could not add \(rule.transport.rawValue.uppercased()) port \(rule.hostPort) forwarding rule (status \(status.rawValue)).")
            }
        }

        guard let network = vmnet_network_create(configuration, &status) else {
            return .failure("Could not reserve the vmnet logical network (status \(status.rawValue)). Check the com.apple.vm.networking entitlement.")
        }
        networks[key] = Entry(signature: signature, network: network)
        return .success(VZVmnetNetworkDeviceAttachment(network: network))
    }

    private static func registryKey(for model: VMModelFieldNetworkDevice) -> String {
        switch model.type {
        case .NAT: "nat-\(model.networkIdentifier)"
        case .HostOnly: "host-\(model.networkIdentifier)"
        case .Custom: "custom-\(model.networkIdentifier)"
        default: model.networkIdentifier
        }
    }

    private static func configurationSignature(for model: VMModelFieldNetworkDevice) -> String {
        let rules = model.portForwardingRules
            .map { "\($0.transport.rawValue):\($0.hostPort):\($0.guestAddress):\($0.guestPort)" }
            .sorted()
            .joined(separator: ",")
        return [
            model.type.rawValue,
            model.externalInterfaceName ?? "",
            model.subnetAddress,
            model.subnetMask,
            String(model.mtu),
            rules,
        ].joined(separator: "|")
    }
}
#endif
