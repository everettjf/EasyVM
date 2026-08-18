//
//  MachineSnapshotsView.swift
//  EasyVM
//
//  Created by everettjf on 2026/8/18.
//

import SwiftUI

#if arch(arm64)

@MainActor
class MachineSnapshotsViewStateObject: ObservableObject {
    let rootPath: URL

    @Published var snapshots: [VMSnapshotModel] = []
    @Published var newSnapshotName: String = ""
    @Published var isWorking = false
    @Published var message: String = ""

    init(rootPath: URL) {
        self.rootPath = rootPath
        reload()
    }

    func reload() {
        snapshots = VMSnapshotManager.listSnapshots(vmRootPath: rootPath)
    }

    func createSnapshot() {
        var name = newSnapshotName.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty {
            name = "Snapshot \(snapshots.count + 1)"
        }

        isWorking = true
        message = "Creating snapshot ..."
        let rootPath = self.rootPath
        Task.detached {
            let result = VMSnapshotManager.createSnapshot(vmRootPath: rootPath, name: name)
            await MainActor.run {
                self.isWorking = false
                switch result {
                case .success(let model):
                    self.message = "Snapshot \"\(model.name)\" created"
                    self.newSnapshotName = ""
                case .failure(let error):
                    self.message = error
                }
                self.reload()
            }
        }
    }

    func restoreSnapshot(_ snapshot: VMSnapshotModel) {
        isWorking = true
        message = "Restoring snapshot \"\(snapshot.name)\" ..."
        let rootPath = self.rootPath
        Task.detached {
            let result = VMSnapshotManager.restoreSnapshot(vmRootPath: rootPath, snapshot: snapshot)
            await MainActor.run {
                self.isWorking = false
                switch result {
                case .success:
                    self.message = "Snapshot \"\(snapshot.name)\" restored"
                    // the restored config.json may differ, ask the machine list to reload
                    NotificationCenter.default.post(name: AppConfigManager.newVMChangedNotification, object: nil)
                case .failure(let error):
                    self.message = error
                }
                self.reload()
            }
        }
    }

    func deleteSnapshot(_ snapshot: VMSnapshotModel) {
        isWorking = true
        let rootPath = self.rootPath
        Task.detached {
            let result = VMSnapshotManager.deleteSnapshot(vmRootPath: rootPath, snapshot: snapshot)
            await MainActor.run {
                self.isWorking = false
                switch result {
                case .success:
                    self.message = "Snapshot \"\(snapshot.name)\" deleted"
                case .failure(let error):
                    self.message = error
                }
                self.reload()
            }
        }
    }
}


struct MachineSnapshotsView: View {
    @Environment(\.presentationMode) var presentationMode

    let machineName: String
    @StateObject private var state: MachineSnapshotsViewStateObject

    @State private var restoringSnapshot: VMSnapshotModel?
    @State private var deletingSnapshot: VMSnapshotModel?

    init(machineName: String, rootPath: URL) {
        self.machineName = machineName
        _state = StateObject(wrappedValue: MachineSnapshotsViewStateObject(rootPath: rootPath))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "camera.on.rectangle")
                Text("Snapshots - \(machineName)")
                    .fontWeight(.bold)
                Spacer()
            }

            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle")
                Text("Shut down the virtual machine before creating or restoring a snapshot. Restoring will replace the current machine state with the snapshot.")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            HStack {
                TextField("New snapshot name (optional)", text: $state.newSnapshotName)
                    .textFieldStyle(.roundedBorder)
                Button {
                    state.createSnapshot()
                } label: {
                    Image(systemName: "plus.circle")
                    Text("Create Snapshot")
                }
                .disabled(state.isWorking)
            }

            if state.snapshots.isEmpty {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Text("No snapshots yet")
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    Spacer()
                }
            } else {
                List(state.snapshots) { snapshot in
                    HStack {
                        Image(systemName: "camera")
                        VStack(alignment: .leading) {
                            Text(snapshot.name)
                            Text(snapshot.displayDate)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()

                        Button {
                            restoringSnapshot = snapshot
                        } label: {
                            Image(systemName: "arrow.counterclockwise.circle")
                            Text("Restore")
                        }
                        .disabled(state.isWorking)

                        Button {
                            deletingSnapshot = snapshot
                        } label: {
                            Image(systemName: "trash")
                        }
                        .disabled(state.isWorking)
                    }
                    .padding(.vertical, 2)
                }
            }

            HStack {
                if state.isWorking {
                    ProgressView()
                        .controlSize(.small)
                }
                Text(state.message)
                    .font(.caption)
                    .lineLimit(2)
                Spacer()
                Button {
                    presentationMode.wrappedValue.dismiss()
                } label: {
                    Text("Close")
                }
            }
        }
        .padding()
        .frame(width: 560, height: 420)
        .confirmationDialog(
            "Restore snapshot \"\(restoringSnapshot?.name ?? "")\" ? Current machine state will be replaced.",
            isPresented: Binding(get: { restoringSnapshot != nil }, set: { if !$0 { restoringSnapshot = nil } })
        ) {
            Button("Restore", role: .destructive) {
                if let snapshot = restoringSnapshot {
                    state.restoreSnapshot(snapshot)
                }
                restoringSnapshot = nil
            }
            Button("Cancel", role: .cancel) {
                restoringSnapshot = nil
            }
        }
        .confirmationDialog(
            "Delete snapshot \"\(deletingSnapshot?.name ?? "")\" ? This can not be undone.",
            isPresented: Binding(get: { deletingSnapshot != nil }, set: { if !$0 { deletingSnapshot = nil } })
        ) {
            Button("Delete", role: .destructive) {
                if let snapshot = deletingSnapshot {
                    state.deleteSnapshot(snapshot)
                }
                deletingSnapshot = nil
            }
            Button("Cancel", role: .cancel) {
                deletingSnapshot = nil
            }
        }
    }
}

#endif
