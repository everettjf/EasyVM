import SwiftUI
import Virtualization

#if arch(arm64)
struct VMConfigurationNetworkDevicesEditView: View {
    @Environment(VMConfigurationViewStateObject.self) private var configData
    @Environment(\.dismiss) private var dismiss

    @State private var inputType: VMModelFieldNetworkDevice.DeviceType = .NAT
    @State private var networkIdentifier = "easyvm-default"
    @State private var bridgedInterfaceIdentifier = VZBridgedNetworkInterface.networkInterfaces.first?.identifier ?? ""
    @State private var externalInterfaceName = ""
    @State private var subnetAddress = "192.168.105.0"
    @State private var subnetMask = "255.255.255.0"
    @State private var mtu: UInt32 = 1500
    @State private var portForwardingRules: [VMPortForwardingRule] = []

    private var bridgedInterfaces: [VZBridgedNetworkInterface] { VZBridgedNetworkInterface.networkInterfaces }
    private var pendingDevice: VMModelFieldNetworkDevice {
        VMModelFieldNetworkDevice(
            type: inputType,
            networkIdentifier: networkIdentifier.trimmingCharacters(in: .whitespacesAndNewlines),
            bridgedInterfaceIdentifier: inputType == .Bridged ? bridgedInterfaceIdentifier : nil,
            externalInterfaceName: externalInterfaceName.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            subnetAddress: subnetAddress.trimmingCharacters(in: .whitespacesAndNewlines),
            subnetMask: subnetMask.trimmingCharacters(in: .whitespacesAndNewlines),
            mtu: mtu,
            portForwardingRules: portForwardingRules
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section("Add Network Device") {
                    Picker("Mode", selection: $inputType) {
                        ForEach(VMModelFieldNetworkDevice.DeviceType.userSelectableCases) { item in
                            Text(displayName(item)).tag(item)
                        }
                    }

                    if inputType == .Bridged {
                        Picker("Host interface", selection: $bridgedInterfaceIdentifier) {
                            ForEach(bridgedInterfaces, id: \.identifier) { interface in
                                Text(verbatim: "\(interface.localizedDisplayName ?? interface.identifier) (\(interface.identifier))")
                                    .tag(interface.identifier)
                            }
                        }
                        if bridgedInterfaces.isEmpty {
                            Text("No bridgeable interface is currently available.")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }

                    if inputType == .HostOnly || inputType == .Custom || (inputType == .NAT && !portForwardingRules.isEmpty) {
                        TextField("Logical network name", text: $networkIdentifier)
                    }

                    if inputType == .Custom || (inputType == .NAT && !portForwardingRules.isEmpty) {
                        TextField("IPv4 subnet", text: $subnetAddress)
                        TextField("IPv4 mask", text: $subnetMask)
                        TextField("External interface (optional, e.g. en0)", text: $externalInterfaceName)
                        TextField("MTU", value: $mtu, format: .number)
                    }

                    if inputType == .NAT || inputType == .Custom {
                        portForwardingEditor
                    }

                    HStack {
                        if let validationError = pendingDevice.validationError {
                            Label(validationError, systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                        Spacer()
                        Button {
                            addDevice()
                        } label: {
                            Label("Add", systemImage: "plus")
                        }
                        .disabled(pendingDevice.validationError != nil)
                    }
                }

                Section("Current Devices") {
                    ForEach(configData.networkDevices) { item in
                        HStack {
                            Label(item.data.description, systemImage: icon(item.data.type))
                            Spacer()
                            Button(role: .destructive) {
                                configData.networkDevices.removeAll { $0.id == item.id }
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Remove network device")
                        }
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Text("Host-only, custom networks, and port forwarding use macOS 26 vmnet logical networks.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Close") { dismiss() }
            }
            .padding()
        }
        .frame(minWidth: 620, minHeight: 560)
    }

    private var portForwardingEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Port Forwarding")
                    .font(.headline)
                Spacer()
                Button {
                    portForwardingRules.append(VMPortForwardingRule())
                } label: {
                    Label("Add Rule", systemImage: "plus.circle")
                }
            }

            ForEach($portForwardingRules) { $rule in
                HStack {
                    Picker("", selection: $rule.transport) {
                        ForEach(VMPortForwardingRule.Transport.allCases) { transport in
                            Text(transport.rawValue.uppercased()).tag(transport)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 80)
                    TextField("Host port", value: $rule.hostPort, format: .number)
                        .frame(width: 90)
                    Image(systemName: "arrow.right")
                        .foregroundStyle(.secondary)
                    TextField("Guest address", text: $rule.guestAddress)
                    TextField("Guest port", value: $rule.guestPort, format: .number)
                        .frame(width: 90)
                    Button(role: .destructive) {
                        portForwardingRules.removeAll { $0.id == rule.id }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
    }

    private func addDevice() {
        guard pendingDevice.validationError == nil else { return }
        configData.networkDevices.append(VMModelFieldNetworkDeviceItemModel(data: pendingDevice))
    }

    private func displayName(_ type: VMModelFieldNetworkDevice.DeviceType) -> String {
        switch type {
        case .NAT: "NAT (shared Internet)"
        case .Bridged: "Bridged (physical network)"
        case .HostOnly: "Host-only"
        case .Custom: "Custom vmnet"
        case .FileHandle: "File handle"
        }
    }

    private func icon(_ type: VMModelFieldNetworkDevice.DeviceType) -> String {
        switch type {
        case .NAT: "network"
        case .Bridged: "point.3.connected.trianglepath.dotted"
        case .HostOnly: "desktopcomputer.and.macbook"
        case .Custom: "slider.horizontal.3"
        case .FileHandle: "doc"
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

struct VMConfigurationNetworkDevicesEditView_Previews: PreviewProvider {
    static var previews: some View {
        VMConfigurationNetworkDevicesEditView()
            .environment(VMConfigurationViewStateObject())
    }
}
#endif
