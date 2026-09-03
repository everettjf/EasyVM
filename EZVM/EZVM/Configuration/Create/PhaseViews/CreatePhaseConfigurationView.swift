//
//  CreatePhaseConfigurationView.swift
//  EZVM
//
//  Created by everettjf on 2022/9/12.
//

import SwiftUI
import Virtualization


#if arch(arm64)
class CreatePhaseConfigurationViewHandler: VMCreateStepperGuidePhaseHandler {
    
    func verifyForm(context: VMCreateStepperGuidePhaseContext) -> VMOSResultVoid {
        guard context.formData.provisionsMacGuest else { return .success }
        guard context.configData.osType == .macOS else {
            return .failure("Guest provisioning is available only for macOS virtual machines.")
        }
        guard #available(macOS 27.0, *) else {
            return .failure("macOS guest provisioning requires a macOS 27 host.")
        }
        guard context.formData.provisioningPassword == context.formData.provisioningPasswordConfirmation else {
            return .failure("The guest account passwords do not match.")
        }
        do {
            let options = VZMacGuestProvisioningOptions()
            options.fullName = context.formData.provisioningFullName
            options.username = context.formData.provisioningUsername
            options.password = context.formData.provisioningPassword
            options.logsInAutomatically = context.formData.provisioningAutomaticLogin
            options.enablesRemoteLogin = context.formData.provisioningRemoteLogin
            try options.validate()
        } catch {
            return .failure("Guest provisioning settings are invalid: \(error.localizedDescription)")
        }
        return .success
    }
    func onStepMovedIn(context: VMCreateStepperGuidePhaseContext) async -> VMOSResultVoid {
        return .success
    }
}


struct CreatePhaseConfigurationView: View {
    @Environment(VMCreateViewStateObject.self) private var formData
    @Environment(VMConfigurationViewStateObject.self) private var configData

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Choose resources")
                        .font(.title2.weight(.semibold))
                    Text("Recommended values are already selected for this Mac.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                CreateResourceControlsView()

                DisclosureGroup("Advanced hardware") {
                    VMCreateConfigurationView(includePrimaryResources: false)
                        .padding(.top, 8)
                }

                if configData.osType == .macOS {
                    guestProvisioningSection
                }
            }
            .frame(maxWidth: 720, alignment: .leading)
            .padding(.bottom, 12)
        }
    }

    private var guestProvisioningAvailable: Bool {
        VirtualizationCapability.guestProvisioning.isAvailable
    }

    private var guestProvisioningSection: some View {
        @Bindable var formData = formData
        return GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Create the first macOS account automatically", isOn: $formData.provisionsMacGuest)
                    .disabled(!guestProvisioningAvailable)

                if !guestProvisioningAvailable {
                    Text("Requires a macOS 27 host.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if formData.provisionsMacGuest {
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                        GridRow {
                            Text("Full name")
                            TextField("EZVM User", text: $formData.provisioningFullName)
                        }
                        GridRow {
                            Text("Username")
                            TextField("ezvm", text: $formData.provisioningUsername)
                                .textContentType(.username)
                        }
                        GridRow {
                            Text("Password")
                            SecureField("Required", text: $formData.provisioningPassword)
                                .textContentType(.newPassword)
                        }
                        GridRow {
                            Text("Confirm")
                            SecureField("Repeat password", text: $formData.provisioningPasswordConfirmation)
                                .textContentType(.newPassword)
                        }
                    }
                    Toggle("Log in automatically", isOn: $formData.provisioningAutomaticLogin)
                    Toggle("Enable Remote Login (SSH)", isOn: $formData.provisioningRemoteLogin)
                    Text("The password stays in this Mac’s Keychain until you confirm that macOS setup completed. It is never stored in the virtual machine bundle.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(4)
        } label: {
            Label("macOS 27 First-Boot Provisioning", systemImage: "person.crop.circle.badge.checkmark")
        }
    }
}

private struct CreateResourceControlsView: View {
    @Environment(VMConfigurationViewStateObject.self) private var configData

    private let gibibyte = UInt64(1024 * 1024 * 1024)

    var body: some View {
        VStack(spacing: 0) {
            resourceRow(
                title: "Processors",
                detail: "\(ProcessInfo.processInfo.processorCount) logical cores available",
                value: "\(configData.cpuCount) CPU"
            ) {
                Slider(value: cpuBinding, in: Double(VMModelFieldCPU.minCount())...Double(VMModelFieldCPU.maxCount()), step: 1)
                    .accessibilityLabel("Processors")
                    .accessibilityValue("\(configData.cpuCount)")
            }

            Divider()

            resourceRow(
                title: "Memory",
                detail: "\(hostMemoryDescription) installed · \(remainingMemoryDescription) remains",
                value: "\(memoryGiB) GB"
            ) {
                Slider(value: memoryBinding, in: minimumMemoryGiB...maximumMemoryGiB, step: 1)
                    .accessibilityLabel("Memory")
                    .accessibilityValue("\(memoryGiB) gigabytes")
            }

            Divider()

            resourceRow(
                title: "Storage",
                detail: "\(primaryDiskFormat) · grows as needed",
                value: "\(storageGiB) GB"
            ) {
                Slider(value: storageBinding, in: minimumStorageGiB...maximumStorageGiB, step: 8)
                    .accessibilityLabel("Storage")
                    .accessibilityValue("\(storageGiB) gigabytes")
            }
        }
        .padding(.horizontal, 18)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(.separator.opacity(0.5), lineWidth: 1)
        }
    }

    private func resourceRow<Control: View>(
        title: String,
        detail: String,
        value: String,
        @ViewBuilder control: () -> Control
    ) -> some View {
        HStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).fontWeight(.medium)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 180, alignment: .leading)

            control()

            Text(value)
                .monospacedDigit()
                .frame(width: 72, alignment: .trailing)
        }
        .padding(.vertical, 16)
    }

    private var cpuBinding: Binding<Double> {
        Binding(
            get: { Double(configData.cpuCount) },
            set: { configData.cpuCount = Int($0.rounded()) }
        )
    }

    private var memoryBinding: Binding<Double> {
        Binding(
            get: { Double(configData.memorySize / gibibyte) },
            set: { configData.memorySize = UInt64($0.rounded()) * gibibyte }
        )
    }

    private var storageBinding: Binding<Double> {
        Binding(
            get: { Double(primaryStorage.size / gibibyte) },
            set: { updatePrimaryStorage(size: UInt64($0.rounded()) * gibibyte) }
        )
    }

    private var minimumMemoryGiB: Double {
        max(1, Double(VMModelFieldMemory.minSize() / gibibyte))
    }

    private var maximumMemoryGiB: Double {
        let hostGiB = Double(ProcessInfo.processInfo.physicalMemory / gibibyte)
        return max(minimumMemoryGiB, min(hostGiB - 2, Double(VMModelFieldMemory.maxSize() / gibibyte)))
    }

    private var minimumStorageGiB: Double {
        let rawMinimum = Double(VMModelFieldStorageDevice.minDiskSize()) / Double(gibibyte)
        return max(16, ceil(rawMinimum / 8) * 8)
    }

    private var maximumStorageGiB: Double {
        max(minimumStorageGiB, min(512, Double(VMModelFieldStorageDevice.maxDiskSize() / gibibyte)))
    }

    private var primaryStorage: VMModelFieldStorageDevice {
        configData.storageDevices.first(where: { $0.data.type == .Block })?.data ?? .default()
    }

    private var memoryGiB: UInt64 { configData.memorySize / gibibyte }
    private var storageGiB: UInt64 { primaryStorage.size / gibibyte }
    private var primaryDiskFormat: String { primaryStorage.format.rawValue.uppercased() }

    private var hostMemoryDescription: String {
        ByteCountFormatter.string(fromByteCount: Int64(ProcessInfo.processInfo.physicalMemory), countStyle: .memory)
    }

    private var remainingMemoryDescription: String {
        let remaining = ProcessInfo.processInfo.physicalMemory > configData.memorySize
            ? ProcessInfo.processInfo.physicalMemory - configData.memorySize
            : 0
        return ByteCountFormatter.string(fromByteCount: Int64(remaining), countStyle: .memory)
    }

    private func updatePrimaryStorage(size: UInt64) {
        guard let index = configData.storageDevices.firstIndex(where: { $0.data.type == .Block }) else { return }
        let existing = configData.storageDevices[index].data
        configData.storageDevices[index] = VMModelFieldStorageDeviceItemModel(
            data: VMModelFieldStorageDevice(
                type: existing.type,
                size: size,
                imagePath: existing.imagePath,
                format: existing.format
            )
        )
    }
}

final class CreatePhaseReviewViewHandler: VMCreateStepperGuidePhaseHandler {
    func verifyForm(context: VMCreateStepperGuidePhaseContext) -> VMOSResultVoid { .success }
    func onStepMovedIn(context: VMCreateStepperGuidePhaseContext) async -> VMOSResultVoid { .success }
}

struct CreatePhaseReviewView: View {
    @Environment(VMCreateViewStateObject.self) private var formData
    @Environment(VMConfigurationViewStateObject.self) private var configData

    private let gibibyte = UInt64(1024 * 1024 * 1024)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Ready to create \(configData.name)")
                        .font(.title2.weight(.semibold))
                    Text("Review your choices. Nothing downloads until you click Create.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                reviewSection("System", systemImage: configData.osType == .macOS ? "apple.logo" : "pc") {
                    reviewRow("Image", formData.systemImageSelection.title)
                    reviewRow("Source", formData.systemImageSelection.detail)
                }

                reviewSection("Machine", systemImage: "desktopcomputer") {
                    reviewRow("Name", configData.name)
                    reviewRow("Location", formData.rootPath)
                }

                reviewSection("Resources", systemImage: "slider.horizontal.3") {
                    reviewRow("Hardware", "\(configData.cpuCount) CPU · \(configData.memorySize / gibibyte) GB memory")
                    reviewRow("Storage", storageSummary)
                    reviewRow("Shared folders", sharingSummary)
                }

                if configData.osType == .macOS {
                    reviewSection("First Boot", systemImage: "person.crop.circle.badge.checkmark") {
                        if formData.provisionsMacGuest {
                            reviewRow(
                                "Account",
                                "\(formData.provisioningFullName) · \(formData.provisioningUsername)"
                            )
                            reviewRow(
                                "Automatic login",
                                formData.provisioningAutomaticLogin ? "Enabled" : "Off"
                            )
                            reviewRow(
                                "Remote Login",
                                formData.provisioningRemoteLogin ? "SSH enabled" : "Off"
                            )
                            reviewRow(
                                "Password",
                                "Stored in this Mac’s Keychain until you confirm setup completed"
                            )
                        } else {
                            reviewRow("Setup", "Complete macOS Setup Assistant manually")
                            reviewRow("Password", "Not stored by EZVM")
                        }
                    }
                }
            }
            .frame(maxWidth: 720, alignment: .leading)
            .padding(.bottom, 12)
        }
    }

    private func reviewSection<Content: View>(
        _ title: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .padding(.leading, 2)

            VStack(spacing: 0) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(.separator.opacity(0.45), lineWidth: 1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func reviewRow(_ label: String, _ value: String) -> some View {
        LabeledContent {
            Text(value)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text(label)
                .fontWeight(.medium)
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }

    private var storageSummary: String {
        guard let disk = configData.storageDevices.first(where: { $0.data.type == .Block })?.data else {
            return "No virtual disk"
        }
        return "\(disk.size / gibibyte) GB · \(disk.format.rawValue.uppercased())"
    }

    private var sharingSummary: String {
        let count = configData.directorySharingDevices.reduce(0) { $0 + $1.data.items.count }
        return count == 0 ? "None · can be added later" : "\(count) folder\(count == 1 ? "" : "s")"
    }
}

struct CreatePhaseConfigurationView_Previews: PreviewProvider {
    static var previews: some View {
        CreatePhaseConfigurationView()
            .environment(VMCreateViewStateObject())
            .environment(VMConfigurationViewStateObject())
    }
}


#endif
