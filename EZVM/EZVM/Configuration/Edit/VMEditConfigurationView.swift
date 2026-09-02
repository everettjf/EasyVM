import SwiftUI

#if arch(arm64)
struct VMEditConfigurationView: View {
    private enum Category: String, CaseIterable, Identifiable {
        case general = "General", hardware = "Hardware", devices = "Devices", sharing = "Sharing", linux = "Linux"
        var id: Self { self }
        var symbol: String {
            switch self {
            case .general: "info.circle"
            case .hardware: "cpu"
            case .devices: "externaldrive.connected.to.line.below"
            case .sharing: "folder"
            case .linux: "terminal"
            }
        }
    }

    @Environment(\.dismiss) private var dismiss
    @State private var configData: VMConfigurationViewStateObject
    @State private var selection: Category = .general
    @State private var saveError: String?
    let model: VMModel

    init(model: VMModel) {
        self.model = model
        _configData = State(initialValue: VMConfigurationViewStateObject(configModel: model.config))
    }

    var body: some View {
        VStack(spacing: 0) {
            categoryBar
            Divider()
            ScrollView {
                categoryContent
                    .frame(maxWidth: 760, alignment: .topLeading)
                    .padding(28)
            }
            Divider()
            footer
        }
        .environment(configData)
        .frame(minWidth: 720, idealWidth: 820, minHeight: 600, idealHeight: 680)
        .alert("Settings Could Not Be Saved", isPresented: Binding(
            get: { saveError != nil },
            set: { if !$0 { saveError = nil } }
        )) {
            Button("OK") { saveError = nil }
        } message: { Text(saveError ?? "") }
    }

    private var categoryBar: some View {
        HStack(spacing: 6) {
            ForEach(availableCategories) { category in
                Button { selection = category } label: {
                    VStack(spacing: 5) {
                        Image(systemName: category.symbol).font(.title3)
                        Text(category.rawValue).font(.caption)
                    }
                    .frame(minWidth: 76)
                    .padding(.vertical, 8)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .foregroundStyle(selection == category ? Color.accentColor : .secondary)
                .background(selection == category ? Color.accentColor.opacity(0.11) : .clear, in: RoundedRectangle(cornerRadius: 9))
                .accessibilityAddTraits(selection == category ? .isSelected : [])
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    @ViewBuilder private var categoryContent: some View {
        switch selection {
        case .general:
            settingsPage("General", subtitle: "Identity and operating system information", symbol: "info.circle") {
                @Bindable var configData = configData
                Form {
                    TextField("Name", text: $configData.name)
                    TextField("Description", text: $configData.remark, axis: .vertical).lineLimit(3...6)
                    LabeledContent("Operating System", value: configData.osType == .macOS ? "macOS" : "Linux")
                    LabeledContent("Location", value: model.rootPath.path(percentEncoded: false))
                }.formStyle(.grouped)
            }
        case .hardware:
            settingsPage("Hardware", subtitle: "Processor, memory, display and storage", symbol: "cpu") {
                Form {
                    Section("Compute") { VMConfigurationCPUView(); VMConfigurationMemoryView() }
                    Section("Display and Storage") { VMConfigurationGraphicDevicesView(); VMConfigurationStorageDevicesView() }
                }.formStyle(.grouped)
            }
        case .devices:
            settingsPage("Devices", subtitle: "Networking, pointer and audio hardware", symbol: "externaldrive.connected.to.line.below") {
                Form {
                    Section("Network") { VMConfigurationNetworkDevicesView() }
                    Section("Input and Audio") { VMConfigurationPointingDevicesView(); VMConfigurationAudioDevicesView() }
                }.formStyle(.grouped)
            }
        case .sharing:
            settingsPage("Sharing", subtitle: "Folders from this Mac available inside the guest", symbol: "folder") {
                Form { VMConfigurationDirectorySharingDevicesView() }.formStyle(.grouped)
            }
        case .linux:
            settingsPage("Linux Integration", subtitle: "Translation, memory and platform features", symbol: "terminal") {
                Form { VMLinuxFeaturesConfigurationSection() }.formStyle(.grouped)
            }
        }
    }

    private func settingsPage<Content: View>(_ title: String, subtitle: String, symbol: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: symbol).font(.system(size: 28)).foregroundStyle(.tint).frame(width: 38)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.title2.weight(.semibold))
                    Text(subtitle).font(.callout).foregroundStyle(.secondary)
                }
            }
            content()
        }
    }

    private var footer: some View {
        HStack {
            Text("Changes take effect the next time the virtual machine starts.").font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            Button("Save") { saveConfig() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(configData.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }.padding(16)
    }

    private var availableCategories: [Category] {
        configData.osType == .linux ? Category.allCases : Category.allCases.filter { $0 != .linux }
    }

    private func saveConfig() {
        switch configData.getConfigModel().writeConfigToFile(path: model.configURL) {
        case .success:
            NotificationCenter.default.post(name: AppConfigManager.newVMChangedNotification, object: nil)
            dismiss()
        case .failure(let error):
            EZVMLog.error("Failed to save VM configuration: \(error)", logger: EZVMLog.storage)
            saveError = error
        }
    }
}
#endif
