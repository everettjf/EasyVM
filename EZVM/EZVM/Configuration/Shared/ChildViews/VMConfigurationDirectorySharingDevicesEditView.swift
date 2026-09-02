//
//  VMConfigurationDirectorySharingDevicesEditView.swift
//  EZVM
//
//  Created by everettjf on 2022/10/6.
//

import SwiftUI

#if arch(arm64)
struct VMConfigurationDirectorySharingDevicesEditView: View {
    @Environment(VMConfigurationViewStateObject.self) private var configData
    @Environment(\.dismiss) private var dismiss
    @State private var isDropTargeted = false
    @State private var dropFeedback: String?
    
    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    if configData.directorySharingDevices.isEmpty {
                        ContentUnavailableView(
                            "No Shared Folders",
                            systemImage: "folder",
                            description: Text("Choose a folder once. EZVM configures the share automatically.")
                        )
                    } else {
                        ForEach(configData.directorySharingDevices) { device in
                            ForEach(device.data.items, id: \.path) { item in
                                HStack(spacing: 12) {
                                    Image(systemName: "folder.fill")
                                        .foregroundStyle(.tint)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.name).fontWeight(.medium)
                                        Text(item.path.path(percentEncoded: false))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    }
                                    Spacer()
                                    Toggle("Read Only", isOn: Binding(
                                        get: { item.readOnly },
                                        set: { configData.setSharedDirectoryReadOnly(deviceID: device.id, path: item.path, readOnly: $0) }
                                    ))
                                    .toggleStyle(.switch)
                                    .controlSize(.small)
                                    Button("Remove", systemImage: "minus.circle", role: .destructive) {
                                        configData.removeSharedDirectory(deviceID: device.id, path: item.path)
                                    }
                                    .labelStyle(.iconOnly)
                                    .buttonStyle(.borderless)
                                    .help("Remove shared folder")
                                }
                            }
                        }
                    }
                } header: {
                    Text("Shared Folders")
                } footer: {
                    Text(configData.osType == .macOS
                         ? "Folders are mounted automatically in macOS after the next start."
                         : "Linux shares become available through VirtioFS after the next start.")
                }
            }
            .formStyle(.grouped)
            .overlay {
                if isDropTargeted {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(Color.accentColor.opacity(0.14))
                        .overlay {
                            Label("Drop folders to share", systemImage: "folder.fill.badge.plus")
                                .font(.title3.weight(.semibold))
                        }
                        .padding(12)
                }
            }
            .dropDestination(for: URL.self) { urls, _ in
                addDroppedURLs(urls)
            } isTargeted: {
                isDropTargeted = $0
            }

            Divider()
            HStack {
                Button("Add Shared Folder…", systemImage: "folder.badge.plus") {
                    chooseFolder()
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()

            if let dropFeedback {
                Text(dropFeedback)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
                    .padding(.bottom, 10)
            }
        }
        .frame(minWidth: 560, minHeight: 380)
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

    private func chooseFolder() {
        MacKitUtil.selectDirectory(title: "Choose a Folder to Share") { url in
            guard let url else { return }
            _ = configData.addSharedDirectory(url)
        }
    }
}

struct VMConfigurationDirectorySharingDevicesEditView_Previews: PreviewProvider {
    static var previews: some View {
        VMConfigurationDirectorySharingDevicesEditView()
            .environment(VMConfigurationViewStateObject())
    }
}


#endif
