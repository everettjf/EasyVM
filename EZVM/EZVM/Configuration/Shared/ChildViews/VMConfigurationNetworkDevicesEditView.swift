import SwiftUI

#if arch(arm64)
struct VMConfigurationNetworkDevicesEditView: View {
    @Environment(VMConfigurationViewStateObject.self) private var configData
    @Environment(\.dismiss) private var dismiss
    @State private var draft = VMNetworkDeviceDraft()
    @State private var showingAdvancedOptions = false
    @State private var forwardingTransport: VMModelFieldNetworkDevice.PortForwardingRule.Transport = .tcp
    @State private var forwardingExternalPort = ""
    @State private var forwardingInternalAddress = ""
    @State private var forwardingInternalPort = ""
    @State private var validationMessage: String?
    @State private var pendingRemovalID: UUID?

    private let modeColumns = [
        GridItem(.adaptive(minimum: 190, maximum: 260), spacing: 12, alignment: .top)
    ]

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VMNetworkEditorHeader()

                    GroupBox {
                        VStack(alignment: .leading, spacing: 16) {
                            LazyVGrid(columns: modeColumns, alignment: .leading, spacing: 12) {
                                ForEach(VMModelFieldNetworkDevice.DeviceType.userSelectableCases) { type in
                                    VMNetworkModeCard(type: type, isSelected: draft.type == type) {
                                        select(type)
                                    }
                                }
                            }

                            VMNetworkReachabilitySummary(type: draft.type)

                            if draft.type.usesVMNet {
                                DisclosureGroup("Advanced VMNet Settings", isExpanded: $showingAdvancedOptions) {
                                    VMNetworkAdvancedSettings(
                                        draft: $draft,
                                        forwardingTransport: $forwardingTransport,
                                        forwardingExternalPort: $forwardingExternalPort,
                                        forwardingInternalAddress: $forwardingInternalAddress,
                                        forwardingInternalPort: $forwardingInternalPort,
                                        validationMessage: $validationMessage,
                                        addPortForwardingRule: addPortForwardingRule
                                    )
                                    .padding(.top, 12)
                                }
                            }

                            if let validationMessage {
                                Label(validationMessage, systemImage: "exclamationmark.triangle.fill")
                                    .font(.callout)
                                    .foregroundStyle(.red)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .accessibilityLabel("Network configuration error: \(validationMessage)")
                            }

                            HStack {
                                Text(additionHint)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button("Add \(draft.type.shortDisplayName) Adapter", systemImage: "plus") {
                                    addNetworkDevice()
                                }
                                .buttonStyle(.borderedProminent)
                            }
                        }
                        .padding(4)
                    } label: {
                        Label("Add an Adapter", systemImage: "plus.circle")
                            .font(.headline)
                    }

                    GroupBox {
                        VStack(spacing: 0) {
                            if configData.networkDevices.isEmpty {
                                ContentUnavailableView(
                                    "No Network Adapters",
                                    systemImage: "network.slash",
                                    description: Text("Add NAT for ordinary internet access, or choose a VMNet mode for an intentional topology.")
                                )
                                .frame(maxWidth: .infinity, minHeight: 140)
                            } else {
                                ForEach(configData.networkDevices) { item in
                                    VMNetworkDeviceRow(item: item) {
                                        pendingRemovalID = item.id
                                    }
                                    if item.id != configData.networkDevices.last?.id {
                                        Divider()
                                    }
                                }
                            }
                        }
                    } label: {
                        Label("Current Adapters", systemImage: "rectangle.stack")
                            .font(.headline)
                    }
                }
                .padding(24)
            }

            Divider()
            HStack {
                Text("Changes take effect the next time this virtual machine starts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
        }
        .frame(minWidth: 700, idealWidth: 760, minHeight: 600, idealHeight: 680)
        .confirmationDialog(
            "Remove this network adapter?",
            isPresented: Binding(
                get: { pendingRemovalID != nil },
                set: { if !$0 { pendingRemovalID = nil } }
            )
        ) {
            Button("Remove Adapter", role: .destructive) {
                guard let pendingRemovalID else { return }
                configData.networkDevices.removeAll { $0.id == pendingRemovalID }
                self.pendingRemovalID = nil
            }
            Button("Cancel", role: .cancel) { pendingRemovalID = nil }
        } message: {
            Text(removalMessage)
        }
    }

    private var additionHint: String {
        switch draft.type {
        case .NAT: "Recommended for a single everyday virtual machine."
        case .VMNetShared: "Requires the VMNet entitlement in the signed EZVM build."
        case .VMNetHost: "Private by design: this adapter does not provide internet access."
        case .FileHandle: "Legacy adapters cannot be added."
        }
    }

    private var removalMessage: String {
        if configData.networkDevices.count == 1 {
            return "This is the last adapter. The virtual machine will have no network connection after the next start."
        }
        return "The virtual machine will stop using this connection after the next start."
    }

    private func select(_ type: VMModelFieldNetworkDevice.DeviceType) {
        draft.type = type
        validationMessage = nil
        if !type.usesVMNet { showingAdvancedOptions = false }
    }

    private func addNetworkDevice() {
        switch draft.build() {
        case .success(let model):
            validationMessage = nil
            configData.networkDevices.append(VMModelFieldNetworkDeviceItemModel(data: model))
            draft = VMNetworkDeviceDraft(type: draft.type)
            showingAdvancedOptions = false
        case .failure(let error):
            validationMessage = error
        }
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
        var candidate = draft
        candidate.type = .VMNetShared
        candidate.portForwardingRules.append(rule)
        if case let .failure(error) = candidate.build(vmnetEntitlementGranted: true) {
            validationMessage = error
            return
        }
        draft.portForwardingRules.append(rule)
        validationMessage = nil
        forwardingExternalPort = ""
        forwardingInternalAddress = ""
        forwardingInternalPort = ""
    }
}

private struct VMNetworkEditorHeader: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Network Adapters")
                .font(.title2.weight(.semibold))
            Text("Choose the connection outcome first. Most virtual machines only need NAT; VMNet details stay optional until you need a deliberate topology.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct VMNetworkModeCard: View {
    let type: VMModelFieldNetworkDevice.DeviceType
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: type.symbolName)
                        .font(.title3)
                        .foregroundStyle(modeIconColor)
                    Spacer()
                    Image(systemName: selectionSymbol)
                        .foregroundStyle(selectionColor)
                }
                Text(type.shortDisplayName)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(type.outcomeDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 142, alignment: .topLeading)
            .background(
                isSelected ? Color.accentColor.opacity(0.10) : Color.secondary.opacity(0.06),
                in: .rect(cornerRadius: 12)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isSelected ? Color.accentColor : Color.secondary.opacity(0.18), lineWidth: isSelected ? 2 : 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(type.shortDisplayName)
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .accessibilityHint(type.outcomeDescription)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var modeIconColor: Color {
        isSelected ? .accentColor : .secondary
    }

    private var selectionSymbol: String {
        isSelected ? "checkmark.circle.fill" : "circle"
    }

    private var selectionColor: Color {
        isSelected ? .accentColor : .secondary.opacity(0.55)
    }
}

private struct VMNetworkReachabilitySummary: View {
    let type: VMModelFieldNetworkDevice.DeviceType

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.triangle.branch")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Reachability")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(type.reachabilitySummary)
                    .font(.callout.weight(.medium))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.06), in: .rect(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }
}

private struct VMNetworkAdvancedSettings: View {
    @Binding var draft: VMNetworkDeviceDraft
    @Binding var forwardingTransport: VMModelFieldNetworkDevice.PortForwardingRule.Transport
    @Binding var forwardingExternalPort: String
    @Binding var forwardingInternalAddress: String
    @Binding var forwardingInternalPort: String
    @Binding var validationMessage: String?
    let addPortForwardingRule: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
                GridRow {
                    Text("Logical network")
                    TextField("Optional shared name", text: $draft.networkIdentifier)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("IPv4 subnet")
                    HStack {
                        TextField("Automatic", text: $draft.ipv4Subnet)
                        TextField("Subnet mask", text: $draft.ipv4SubnetMask)
                    }
                    .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("MTU")
                    TextField("1500", text: $draft.mtu)
                        .textFieldStyle(.roundedBorder)
                }
                if draft.type == .VMNetShared {
                    GridRow {
                        Text("External interface")
                        TextField("Automatic, or interface such as en0", text: $draft.externalInterface)
                            .textFieldStyle(.roundedBorder)
                    }
                }
            }

            Text("Leave the network name and subnet blank to let macOS reserve an isolated logical network automatically. Reuse the same name only when adapters should join the same topology.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if draft.type == .VMNetShared {
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    Text("Port Forwarding")
                        .font(.subheadline.weight(.semibold))
                    forwardingEditor
                    Text("Host-port availability is checked when the virtual machine starts; another process can still claim a port after this preflight.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(draft.portForwardingRules) { rule in
                        HStack {
                            Text("\(rule.transport.displayName) · Host :\(rule.externalPort) → \(rule.internalAddress):\(rule.internalPort)")
                                .font(.callout.monospacedDigit())
                            Spacer()
                            Button("Remove Rule", systemImage: "trash", role: .destructive) {
                                draft.portForwardingRules.removeAll { $0.id == rule.id }
                                validationMessage = nil
                            }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                        }
                    }
                }
            }
        }
    }

    private var forwardingEditor: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
            GridRow {
                Text("Protocol")
                    .foregroundStyle(.secondary)
                Picker("Transport", selection: $forwardingTransport) {
                    ForEach(VMModelFieldNetworkDevice.PortForwardingRule.Transport.allCases) { transport in
                        Text(transport.displayName).tag(transport)
                    }
                }
                .labelsHidden()
                .frame(width: 90)
                Text("Host port")
                    .foregroundStyle(.secondary)
                TextField("8080", text: $forwardingExternalPort)
                    .frame(width: 100)
            }
            GridRow {
                Text("Forwards to")
                    .foregroundStyle(.secondary)
                TextField("Guest IPv4", text: $forwardingInternalAddress)
                    .frame(minWidth: 180)
                Text("Guest port")
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    TextField("80", text: $forwardingInternalPort)
                        .frame(width: 100)
                    Button("Add Rule", systemImage: "plus", action: addPortForwardingRule)
                        .accessibilityHint("Add this port-forwarding rule")
                }
            }
        }
        .textFieldStyle(.roundedBorder)
    }
}

private struct VMNetworkDeviceRow: View {
    let item: VMModelFieldNetworkDeviceItemModel
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 13) {
            Image(systemName: item.data.type.symbolName)
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.data.type.shortDisplayName)
                    .font(.headline)
                Text(item.data.type.reachabilitySummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(item.data.configurationSummary)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }
            Spacer()
            Button("Remove Adapter", systemImage: "trash", role: .destructive, action: remove)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .accessibilityHint("Remove this adapter after confirmation")
        }
        .padding(.vertical, 11)
        .accessibilityElement(children: .contain)
    }
}

struct VMConfigurationNetworkDevicesEditView_Previews: PreviewProvider {
    static var previews: some View {
        VMConfigurationNetworkDevicesEditView()
            .environment(VMConfigurationViewStateObject())
    }
}
#endif
