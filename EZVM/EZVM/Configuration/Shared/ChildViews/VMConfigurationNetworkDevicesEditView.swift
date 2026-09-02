import SwiftUI

#if arch(arm64)
struct VMConfigurationNetworkDevicesEditView: View {
    @Environment(VMConfigurationViewStateObject.self) private var configData
    @Environment(\.dismiss) private var dismiss
    @State private var inputType: VMModelFieldNetworkDevice.DeviceType = .NAT
    @State private var networkIdentifier = ""
    @State private var ipv4Subnet = ""
    @State private var ipv4SubnetMask = ""
    @State private var externalInterface = ""
    @State private var mtu = "1500"
    @State private var forwardingTransport: VMModelFieldNetworkDevice.PortForwardingRule.Transport = .tcp
    @State private var forwardingExternalPort = ""
    @State private var forwardingInternalAddress = ""
    @State private var forwardingInternalPort = ""
    @State private var portForwardingRules: [VMModelFieldNetworkDevice.PortForwardingRule] = []
    @State private var validationMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section("Add Network Device") {
                    Picker("Mode", selection: $inputType) {
                        ForEach(VMModelFieldNetworkDevice.DeviceType.userSelectableCases) { type in
                            Text(type.displayName).tag(type)
                        }
                    }

                    if inputType == .VMNetShared || inputType == .VMNetHost {
                        TextField("Logical network name (optional)", text: $networkIdentifier)
                        TextField("IPv4 subnet (optional)", text: $ipv4Subnet)
                        TextField("Subnet mask (optional)", text: $ipv4SubnetMask)
                        TextField("MTU", text: $mtu)
                        if inputType == .VMNetShared {
                            TextField("External interface (optional, for example en0)", text: $externalInterface)
                            LabeledContent("Port forwarding") {
                                HStack {
                                    Picker("Transport", selection: $forwardingTransport) {
                                        ForEach(VMModelFieldNetworkDevice.PortForwardingRule.Transport.allCases) { transport in
                                            Text(transport.displayName).tag(transport)
                                        }
                                    }
                                    .labelsHidden()
                                    .frame(width: 80)
                                    TextField("Host port", text: $forwardingExternalPort)
                                    Text("→")
                                    TextField("Guest IPv4", text: $forwardingInternalAddress)
                                    TextField("Guest port", text: $forwardingInternalPort)
                                    Button("Add") { addPortForwardingRule() }
                                }
                            }
                            ForEach(portForwardingRules) { rule in
                                HStack {
                                    Text("\(rule.transport.displayName) :\(rule.externalPort) → \(rule.internalAddress):\(rule.internalPort)")
                                    Spacer()
                                    Button(role: .destructive) {
                                        portForwardingRules.removeAll { $0.id == rule.id }
                                    } label: {
                                        Image(systemName: "trash")
                                    }
                                    .buttonStyle(.borderless)
                                }
                            }
                        }
                        Text("VMNet modes use EZVM’s signed VMNet entitlement. Leave subnet fields blank to let macOS reserve a network automatically.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if let validationMessage {
                        Text(validationMessage)
                            .foregroundStyle(.red)
                    }

                    Button {
                        addNetworkDevice()
                    } label: {
                        Label("Add Network Device", systemImage: "plus")
                    }
                }

                Section("Current Devices") {
                    ForEach(configData.networkDevices) { item in
                        HStack {
                            Label(item.data.description, systemImage: "network")
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
                Text("Existing machines keep standard NAT unless you explicitly add a VMNet device.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Close") { dismiss() }
            }
            .padding()
        }
        .frame(minWidth: 520, minHeight: 420)
    }

    private func addNetworkDevice() {
        let model = VMModelFieldNetworkDevice(
            type: inputType,
            networkIdentifier: networkIdentifier,
            ipv4Subnet: ipv4Subnet,
            ipv4SubnetMask: ipv4SubnetMask,
            externalInterface: externalInterface,
            mtu: inputType == .NAT ? nil : UInt32(mtu),
            portForwardingRules: inputType == .VMNetShared ? portForwardingRules : []
        )
        if inputType != .NAT, UInt32(mtu) == nil {
            validationMessage = "MTU must be a whole number between 576 and 9000."
            return
        }
        if let error = model.validationError {
            validationMessage = error
            return
        }
        validationMessage = nil
        configData.networkDevices.append(VMModelFieldNetworkDeviceItemModel(data: model))
    }

    private func addPortForwardingRule() {
        guard let externalPort = UInt16(forwardingExternalPort), externalPort > 0,
              let internalPort = UInt16(forwardingInternalPort), internalPort > 0,
              !forwardingInternalAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            validationMessage = "Enter valid host and guest ports (1–65535) and a guest IPv4 address."
            return
        }
        let rule = VMModelFieldNetworkDevice.PortForwardingRule(
            transport: forwardingTransport,
            externalPort: externalPort,
            internalAddress: forwardingInternalAddress,
            internalPort: internalPort
        )
        let candidate = VMModelFieldNetworkDevice(
            type: .VMNetShared,
            portForwardingRules: portForwardingRules + [rule]
        )
        if let error = candidate.validationError,
           !error.contains("does not have the VMNet entitlement") {
            validationMessage = error
            return
        }
        validationMessage = nil
        portForwardingRules.append(rule)
        forwardingExternalPort = ""
        forwardingInternalAddress = ""
        forwardingInternalPort = ""
    }
}

struct VMConfigurationNetworkDevicesEditView_Previews: PreviewProvider {
    static var previews: some View {
        VMConfigurationNetworkDevicesEditView()
            .environment(VMConfigurationViewStateObject())
    }
}
#endif
