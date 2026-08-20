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
        if context.formData.imagePath.isEmpty {
            return .failure("Please choose a system version to download, or pick a local ipsw/iso file")
        }
        if !FileManager.default.fileExists(atPath: context.formData.imagePath) {
            return .failure("System image file does not exist : \(context.formData.imagePath)")
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

    @State private var downloadSource: SystemImageDownloadViewState.ImageSource?

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
        .sheet(item: $downloadSource) { source in
            SystemImageDownloadView(initialSource: source)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Choose a system")
                .font(.title2.weight(.semibold))
            Text("Select an operating system and an image. Downloads are saved for reuse.")
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
                selectedPath: formData.imagePath,
                onDownload: presentDownload,
                onChooseLocal: selectFromFileSystem
            )
        } else {
            LinuxImageSelectionView(
                selectedPath: formData.imagePath,
                onDownload: presentDownload,
                onChooseLocal: selectFromFileSystem
            )
        }
    }

    private var selectedImageSummary: some View {
        GroupBox {
            HStack(spacing: 12) {
                Image(systemName: formData.imagePath.isEmpty ? "circle.dashed" : "checkmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(formData.imagePath.isEmpty ? Color.secondary : Color.green)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    Text(formData.imagePath.isEmpty ? "No system image selected" : "Ready to continue")
                        .font(.headline)
                    Text(formData.imagePath.isEmpty ? "Choose a download above or select an image from disk." : formData.imagePath)
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
    }

    private func presentDownload(_ source: SystemImageDownloadViewState.ImageSource) {
        downloadSource = source
    }

    private func switchOSType(_ osType: VMOSType) {
        guard configData.osType != osType else { return }
        configData.osType = osType
        configData.resetDefaultConfig()
        formData.imagePath = ""
    }

    private func selectFromFileSystem() {
        let fileType = configData.osType == .macOS ? "IPSW" : "ISO"
        MacKitUtil.selectFile(title: "Choose a \(fileType) system image") { path in
            guard let path else { return }
            formData.imagePath = path.path(percentEncoded: false)
        }
    }
}

private struct MacOSImageSelectionView: View {
    let selectedPath: String
    let onDownload: (SystemImageDownloadViewState.ImageSource) -> Void
    let onChooseLocal: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SelectionSectionHeading(
                title: "macOS restore image",
                subtitle: "Official Apple restore images for Apple silicon virtual machines."
            )

            ImageChoiceButton(
                title: "Latest compatible macOS",
                detail: "Automatically resolved through Apple",
                systemImage: "sparkles",
                accent: .blue,
                badge: VMImageStore.exists(fileName: "macOS-Latest.ipsw") ? "Downloaded" : "Recommended",
                identifier: "macos-latest-image"
            ) {
                onDownload(.latestAvailable)
            }

            VStack(spacing: 8) {
                ForEach(VMSystemImageCatalog.macOSItems) { item in
                    ImageChoiceButton(
                        title: item.name,
                        detail: item.detail,
                        systemImage: "shippingbox",
                        accent: .indigo,
                        badge: cachedBadge(for: item),
                        identifier: "macos-image-\(item.id)"
                    ) {
                        onDownload(.catalog(item))
                    }
                }
            }

            LocalImageButton(fileType: "IPSW", selectedPath: selectedPath, action: onChooseLocal)
        }
    }

    private func cachedBadge(for item: VMSystemImageCatalogItem) -> String? {
        let ext = item.url.pathExtension.isEmpty ? "ipsw" : item.url.pathExtension
        return VMImageStore.exists(fileName: "\(item.id).\(ext)") ? "Downloaded" : nil
    }
}

private struct LinuxImageSelectionView: View {
    let selectedPath: String
    let onDownload: (SystemImageDownloadViewState.ImageSource) -> Void
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
                        identifier: "linux-image-\(item.id)"
                    ) {
                        onDownload(.catalog(item))
                    }
                }
            }

            ImageChoiceButton(
                title: "Download from a custom URL",
                detail: "Use a direct link to another ARM64 ISO",
                systemImage: "link",
                accent: .orange,
                identifier: "linux-custom-url"
            ) {
                onDownload(.inputURL)
            }

            LocalImageButton(fileType: "ISO", selectedPath: selectedPath, action: onChooseLocal)
        }
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
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(.separator.opacity(0.5), lineWidth: 1)
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
