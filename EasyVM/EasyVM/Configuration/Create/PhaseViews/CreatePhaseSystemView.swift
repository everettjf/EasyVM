//
//  CreatePhaseSystemView.swift
//  EasyVM
//
//  Created by everettjf on 2026/8/18.
//

import SwiftUI

#if arch(arm64)

class CreatePhaseSystemViewHandler: VMCreateStepperGuidePhaseHandler {
    func verifyForm(context: VMCreateStepperGuidePhaseContext) -> VMOSResultVoid {
        if case .localFile(let url) = context.formData.systemImageSelection,
           !FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
            return .failure("The selected system image no longer exists: \(url.path(percentEncoded: false))")
        }
        return .success
    }

    func onStepMovedIn(context: VMCreateStepperGuidePhaseContext) async -> VMOSResultVoid {
        .success
    }
}

struct CreatePhaseSystemView: View {
    @EnvironmentObject private var formData: VMCreateViewStateObject
    @EnvironmentObject private var configData: VMConfigurationViewStateObject

    @State private var customImageURL = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                operatingSystemPicker
                imageSelection
                selectedImageSummary
            }
            .frame(maxWidth: 720, alignment: .leading)
            .padding(.horizontal, 4)
            .padding(.bottom, 12)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Choose a system")
                .font(.title2.weight(.semibold))
            Text("Choose an image now. Downloading starts only after you click Create.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var operatingSystemPicker: some View {
        Picker("Operating system", selection: Binding(
            get: { configData.osType },
            set: { switchOSType($0) }
        )) {
            Label("macOS", systemImage: "apple.logo")
                .tag(VMOSType.macOS)
            Label("Linux", systemImage: "pc")
                .tag(VMOSType.linux)
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("create-os-picker")
    }

    @ViewBuilder
    private var imageSelection: some View {
        if configData.osType == .macOS {
            MacOSImageSelectionView(
                selection: formData.systemImageSelection,
                customURL: $customImageURL,
                onSelect: selectImage,
                onChooseLocal: selectFromFileSystem
            )
        } else {
            LinuxImageSelectionView(
                selection: formData.systemImageSelection,
                customURL: $customImageURL,
                onSelect: selectImage,
                onChooseLocal: selectFromFileSystem
            )
        }
    }

    private var selectedImageSummary: some View {
        GroupBox {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.green)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    Text(formData.systemImageSelection.title)
                        .font(.headline)
                    Text(formData.systemImageSelection.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("selected-system-image")
        .id(formData.systemImageSelection)
    }

    private func selectImage(_ selection: VMCreateViewStateObject.SystemImageSelection) {
        formData.systemImageSelection = selection
        if case .localFile(let url) = selection {
            formData.imagePath = url.path(percentEncoded: false)
        } else {
            formData.imagePath = ""
        }
    }

    private func switchOSType(_ osType: VMOSType) {
        guard configData.osType != osType else { return }
        configData.osType = osType
        configData.resetDefaultConfig()
        formData.imagePath = ""
        formData.systemImageSelection = osType == .macOS
            ? .latestMacOS
            : .catalog(VMSystemImageCatalog.linuxItems[0])
    }

    private func selectFromFileSystem() {
        let fileType = configData.osType == .macOS ? "IPSW" : "ISO"
        MacKitUtil.selectFile(title: "Choose a \(fileType) system image") { path in
            guard let path else { return }
            selectImage(.localFile(path))
        }
    }
}

private struct MacOSImageSelectionView: View {
    let selection: VMCreateViewStateObject.SystemImageSelection
    @Binding var customURL: String
    let onSelect: (VMCreateViewStateObject.SystemImageSelection) -> Void
    let onChooseLocal: () -> Void

    @StateObject private var catalog = VMMacOSImageCatalogService()
    @State private var showAllReleases = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                SelectionSectionHeading(
                    title: "macOS restore image",
                    subtitle: "Choose the newest compatible release or a specific version from Apple."
                )
                Spacer()
                Button {
                    Task { await catalog.refresh(force: true) }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(catalog.isRefreshing)
                .accessibilityIdentifier("refresh-macos-catalog")
            }

            ImageChoiceButton(
                title: "Latest compatible macOS",
                detail: "Automatically resolved through Apple",
                systemImage: "sparkles",
                accent: .blue,
                badge: VMImageStore.exists(fileName: "macOS-Latest.ipsw") ? "Downloaded" : "Recommended",
                isSelected: selection == .latestMacOS,
                identifier: "macos-latest-image"
            ) {
                onSelect(.latestMacOS)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 7) {
                    if catalog.isRefreshing {
                        ProgressView().controlSize(.small)
                        Text("Updating available versions…")
                    } else if let errorMessage = catalog.errorMessage {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text(errorMessage)
                    } else {
                        Image(systemName: "network").foregroundStyle(.green)
                        Text(catalogStatusText)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                Text("Catalog data from IPSW.me · Restore images download directly from Apple. Specific releases may require newer host device support.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                Text("Recommended releases")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                ForEach(catalog.featuredItems) { item in
                    ImageChoiceButton(
                        title: item.name,
                        detail: item.detail,
                        systemImage: "shippingbox",
                        accent: .indigo,
                        badge: cachedBadge(for: item),
                        isSelected: selectedCatalogID == item.id,
                        identifier: "macos-image-\(item.id)"
                    ) {
                        onSelect(.catalog(item))
                    }
                }

                DisclosureGroup("All available releases (\(catalog.items.count))", isExpanded: $showAllReleases) {
                    LazyVStack(spacing: 8) {
                        ForEach(catalog.items) { item in
                            ImageChoiceButton(
                                title: item.name,
                                detail: item.detail,
                                systemImage: "shippingbox",
                                accent: .indigo,
                                badge: cachedBadge(for: item),
                                isSelected: selectedCatalogID == item.id,
                                identifier: "macos-image-\(item.id)"
                            ) {
                                onSelect(.catalog(item))
                            }
                        }
                    }
                    .padding(.top, 8)
                }
            }

            HStack(spacing: 10) {
                TextField("Direct Apple IPSW URL", text: $customURL)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("macos-custom-url-field")
                Button("Use URL") {
                    guard let url = validatedCustomURL else { return }
                    onSelect(.remoteURL(url))
                }
                .disabled(validatedCustomURL == nil)
            }

            LocalImageButton(fileType: "IPSW", selectedPath: localPath, action: onChooseLocal)
        }
        .task { await catalog.refresh() }
    }

    private var localPath: String {
        if case .localFile(let url) = selection { return url.path(percentEncoded: false) }
        return ""
    }

    private var selectedCatalogID: String? {
        if case .catalog(let item) = selection { return item.id }
        return nil
    }

    private var validatedCustomURL: URL? {
        guard let url = URL(string: customURL),
              url.scheme?.lowercased() == "https",
              url.pathExtension.lowercased() == "ipsw" else { return nil }
        return url
    }

    private var catalogStatusText: String {
        guard let lastUpdated = catalog.lastUpdated else {
            return "Built-in catalog · refreshes automatically"
        }
        if abs(lastUpdated.timeIntervalSinceNow) < 60 {
            return "Online catalog updated just now"
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return "Online catalog updated \(formatter.localizedString(for: lastUpdated, relativeTo: Date()))"
    }

    private func cachedBadge(for item: VMSystemImageCatalogItem) -> String? {
        let ext = item.url.pathExtension.isEmpty ? "ipsw" : item.url.pathExtension
        return VMImageStore.exists(fileName: "\(item.id).\(ext)") ? "Downloaded" : nil
    }
}

private struct LinuxImageSelectionView: View {
    let selection: VMCreateViewStateObject.SystemImageSelection
    @Binding var customURL: String
    let onSelect: (VMCreateViewStateObject.SystemImageSelection) -> Void
    let onChooseLocal: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SelectionSectionHeading(
                title: "Ubuntu & Linux install image",
                subtitle: "ARM64 installers that run natively on Apple silicon."
            )

            VStack(spacing: 8) {
                ForEach(VMSystemImageCatalog.linuxItems) { item in
                    ImageChoiceButton(
                        title: item.name,
                        detail: linuxDetail(for: item),
                        systemImage: linuxIcon(for: item),
                        accent: item.id.hasPrefix("ubuntu") ? .orange : .purple,
                        badge: linuxBadge(for: item),
                        isSelected: selection == .catalog(item),
                        identifier: "linux-image-\(item.id)"
                    ) {
                        onSelect(.catalog(item))
                    }
                }
            }

            HStack(spacing: 10) {
                TextField("Direct ARM64 ISO URL", text: $customURL)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("linux-custom-url-field")
                Button("Use URL") {
                    guard let url = validatedCustomURL else { return }
                    onSelect(.remoteURL(url))
                }
                .disabled(validatedCustomURL == nil)
            }

            LocalImageButton(fileType: "ISO", selectedPath: localPath, action: onChooseLocal)
        }
    }

    private var localPath: String {
        if case .localFile(let url) = selection { return url.path(percentEncoded: false) }
        return ""
    }

    private var validatedCustomURL: URL? {
        guard let url = URL(string: customURL),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http" else { return nil }
        return url
    }

    private func linuxDetail(for item: VMSystemImageCatalogItem) -> String {
        if item.id == "ubuntu-24.04-server" {
            return "ARM64 · LTS · Lightweight server installer"
        }
        if item.id == "ubuntu-24.04-desktop" {
            return "ARM64 · LTS · Full graphical desktop"
        }
        return item.detail
    }

    private func linuxIcon(for item: VMSystemImageCatalogItem) -> String {
        item.id.contains("desktop") ? "display" : "terminal"
    }

    private func linuxBadge(for item: VMSystemImageCatalogItem) -> String? {
        let ext = item.url.pathExtension.isEmpty ? "iso" : item.url.pathExtension
        if VMImageStore.exists(fileName: "\(item.id).\(ext)") {
            return "Downloaded"
        }
        return item.id == "ubuntu-24.04-server" ? "Recommended" : nil
    }
}

private struct ImageChoiceButton: View {
    let title: String
    let detail: String
    let systemImage: String
    let accent: Color
    var badge: String? = nil
    var isSelected = false
    let identifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: systemImage)
                    .font(.title2)
                    .foregroundStyle(accent)
                    .frame(width: 32)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(title)
                            .font(.headline)
                        if let badge {
                            Text(badge)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(accent)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(accent.opacity(0.12), in: Capsule())
                        }
                    }
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 16)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(isSelected ? accent.opacity(0.10) : Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(isSelected ? accent : Color.secondary.opacity(0.25), lineWidth: isSelected ? 2 : 1)
        }
        .accessibilityLabel("\(title), \(detail)")
        .accessibilityIdentifier(identifier)
    }
}

private struct LocalImageButton: View {
    let fileType: String
    let selectedPath: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: "externaldrive")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    .frame(width: 32)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Choose a local \(fileType) file")
                        .font(.headline)
                    Text(selectedPath.isEmpty ? "Browse this Mac or an external drive" : "Replace the currently selected image")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "folder")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .padding(12)
        }
        .buttonStyle(.plain)
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5]))
                .foregroundStyle(.separator)
        }
        .accessibilityIdentifier("choose-local-system-image")
    }
}

private struct SelectionSectionHeading: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.headline)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

struct CreatePhaseSystemView_Previews: PreviewProvider {
    static let formData = VMCreateViewStateObject()
    static let configData = VMConfigurationViewStateObject()

    static var previews: some View {
        CreatePhaseSystemView()
            .frame(width: 720, height: 620)
            .environmentObject(formData)
            .environmentObject(configData)
    }
}

#endif
