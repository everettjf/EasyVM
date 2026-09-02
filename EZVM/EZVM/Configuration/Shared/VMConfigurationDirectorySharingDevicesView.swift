//
//  VMConfigurationDirectorySharingDevicesView.swift
//  EZVM
//
//  Created by everettjf on 2022/10/5.
//

import SwiftUI
import UniformTypeIdentifiers

#if arch(arm64)
enum VMSharedFolderDrop {
    static func directories(from urls: [URL]) -> [URL] {
        urls.filter { url in
            (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
    }
}

final class CreatePhaseSharingViewHandler: VMCreateStepperGuidePhaseHandler {
    func verifyForm(context: VMCreateStepperGuidePhaseContext) -> VMOSResultVoid { .success }
    func onStepMovedIn(context: VMCreateStepperGuidePhaseContext) async -> VMOSResultVoid { .success }
}

struct CreatePhaseSharingView: View {
    @Environment(VMConfigurationViewStateObject.self) private var configData
    @State private var isDropTargeted = false
    @State private var feedbackMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Share folders")
                        .font(.title2.weight(.semibold))
                    Text("Make files from your Mac available inside the virtual machine. You can also do this later.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                dropArea

                if let feedbackMessage {
                    Label(feedbackMessage, systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("shared-folder-feedback")
                }

                if sharedItems.isEmpty {
                    Text("No folders selected. Choose Not Now or Continue to skip sharing.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 0) {
                        ForEach(sharedItems, id: \.item.path) { entry in
                            sharedFolderRow(entry)
                            if entry.item.path != sharedItems.last?.item.path { Divider() }
                        }
                    }
                    .padding(.horizontal, 14)
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(.separator.opacity(0.5), lineWidth: 1)
                    }
                }
            }
            .frame(maxWidth: 720, alignment: .leading)
            .padding(.bottom, 12)
        }
    }

    private var dropArea: some View {
        VStack(spacing: 10) {
            Image(systemName: isDropTargeted ? "folder.fill.badge.plus" : "folder.badge.plus")
                .font(.system(size: 34))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text(isDropTargeted ? "Drop to share" : "Drop folders here")
                .font(.headline)
            Text("Folders remain on your Mac. Nothing is copied into the virtual disk.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Choose Folder…", systemImage: "folder") { chooseFolder() }
        }
        .frame(maxWidth: .infinity, minHeight: 180)
        .background(isDropTargeted ? Color.accentColor.opacity(0.10) : Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(
                    isDropTargeted ? Color.accentColor : Color.secondary.opacity(0.4),
                    style: StrokeStyle(lineWidth: isDropTargeted ? 2 : 1, dash: [7])
                )
        }
        .dropDestination(for: URL.self) { urls, _ in
            addDroppedURLs(urls)
        } isTargeted: {
            isDropTargeted = $0
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Shared folder drop area")
        .accessibilityHint("Drop one or more folders from Finder, or choose a folder")
        .accessibilityIdentifier("shared-folder-drop-area")
    }

    private var sharedItems: [(deviceID: UUID, item: VMModelFieldDirectorySharingDevice.SharingItem, tag: String)] {
        configData.directorySharingDevices.flatMap { device in
            device.data.items.map { (device.id, $0, device.data.tag) }
        }
    }

    private func sharedFolderRow(
        _ entry: (deviceID: UUID, item: VMModelFieldDirectorySharingDevice.SharingItem, tag: String)
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "folder.fill")
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.item.name).fontWeight(.medium)
                Text("\(entry.item.path.path(percentEncoded: false)) · \(guestMountDescription(tag: entry.tag))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Toggle("Read Only", isOn: Binding(
                get: { entry.item.readOnly },
                set: { configData.setSharedDirectoryReadOnly(deviceID: entry.deviceID, path: entry.item.path, readOnly: $0) }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
            Button("Remove", systemImage: "trash", role: .destructive) {
                configData.removeSharedDirectory(deviceID: entry.deviceID, path: entry.item.path)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 12)
    }

    private func addDroppedURLs(_ urls: [URL]) -> Bool {
        let directories = VMSharedFolderDrop.directories(from: urls)
        guard !directories.isEmpty else {
            feedbackMessage = "Only folders can be shared."
            return false
        }
        let added = directories.reduce(into: 0) { count, url in
            if configData.addSharedDirectory(url) { count += 1 }
        }
        let ignored = urls.count - added
        if added > 0 {
            feedbackMessage = ignored == 0
                ? "Added \(added) folder\(added == 1 ? "" : "s")."
                : "Added \(added) folder\(added == 1 ? "" : "s"); ignored \(ignored) invalid or duplicate item\(ignored == 1 ? "" : "s")."
        } else {
            feedbackMessage = "Those folders are already shared or unavailable."
        }
        return added > 0
    }

    private func chooseFolder() {
        MacKitUtil.selectDirectory(title: "Choose a Folder to Share") { url in
            guard let url else { return }
            feedbackMessage = configData.addSharedDirectory(url)
                ? "Added “\(url.lastPathComponent)”."
                : "“\(url.lastPathComponent)” is already shared."
        }
    }

    private func guestMountDescription(tag: String) -> String {
        configData.osType == .macOS ? "mounts automatically" : "VirtioFS tag: \(tag)"
    }
}

struct VMConfigurationDirectorySharingDevicesView: View {
    @Environment(VMConfigurationViewStateObject.self) var configData
    @State private var showingEditView = false
    @State private var isDropTargeted = false
    @State private var dropFeedback: String?
    
    
    var body: some View {
        content
            .sheet(isPresented: $showingEditView) {
                VMConfigurationDirectorySharingDevicesEditView()
            }
    }
    
    var content: some View {
        LabeledContent("Shared Folders") {
            VStack(alignment: .trailing) {
                List(configData.directorySharingDevices) { item in
                    HStack {
                        Spacer()
                        Text(item.data.items.map(\.name).joined(separator: ", "))
                            .lineLimit(2)
                            .multilineTextAlignment(.trailing)
                    }
                }
                .frame(width:400)
                .overlay {
                    if isDropTargeted {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.accentColor.opacity(0.12))
                            .overlay {
                                Label("Drop to share", systemImage: "folder.fill.badge.plus")
                                    .font(.headline)
                            }
                    }
                }
                .dropDestination(for: URL.self) { urls, _ in
                    addDroppedURLs(urls)
                } isTargeted: {
                    isDropTargeted = $0
                }

                if let dropFeedback {
                    Text(dropFeedback)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                
                HStack {
                    Spacer()
                    Button {
                        MacKitUtil.selectDirectory(title: "Choose a Folder to Share") { url in
                            guard let url else { return }
                            _ = configData.addSharedDirectory(url)
                        }
                    } label: {
                        Label("Add Shared Folder", systemImage: "folder.badge.plus")
                    }
                    .help("Choose a folder to share")

                    Button {
                        showingEditView.toggle()
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .help("Manage shared folders")
                }
            }
        }
    }

    private func addDroppedURLs(_ urls: [URL]) -> Bool {
        let directories = VMSharedFolderDrop.directories(from: urls)
        let added = directories.reduce(into: 0) { count, url in
            if configData.addSharedDirectory(url) { count += 1 }
        }
        dropFeedback = added > 0
            ? "Added \(added) shared folder\(added == 1 ? "" : "s")."
            : "Drop folders that are not already shared."
        return added > 0
    }
}

struct VMConfigurationDirectorySharingDevicesView_Previews: PreviewProvider {
    static var previews: some View {
        Form {
            VMConfigurationDirectorySharingDevicesView()
                .environment(VMConfigurationViewStateObject())
        }
        .formStyle(.grouped)
    }
}


#endif
