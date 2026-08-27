import SwiftUI

#if arch(arm64)
struct VMConfigurationNetworkDevicesEditView: View {
    @Environment(VMConfigurationViewStateObject.self) private var configData
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section("Add Network Device") {
                    LabeledContent("Mode", value: "NAT (shared Internet)")
                    Button {
                        configData.networkDevices.append(
                            VMModelFieldNetworkDeviceItemModel(data: .default())
                        )
                    } label: {
                        Label("Add NAT Device", systemImage: "plus")
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
                Text("EZVM currently uses standard NAT networking.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Close") { dismiss() }
            }
            .padding()
        }
        .frame(minWidth: 520, minHeight: 420)
    }
}

struct VMConfigurationNetworkDevicesEditView_Previews: PreviewProvider {
    static var previews: some View {
        VMConfigurationNetworkDevicesEditView()
            .environment(VMConfigurationViewStateObject())
    }
}
#endif
