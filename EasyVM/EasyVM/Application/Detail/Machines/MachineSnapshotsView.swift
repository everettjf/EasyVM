//
//  MachineSnapshotsView.swift
//  EasyVM
//
//  Created by everettjf on 2026/8/18.
//

import SwiftUI
import Observation

#if arch(arm64)

@MainActor
@Observable
class MachineSnapshotsViewStateObject {
    let rootPath: URL

    var snapshots: [VMSnapshotModel] = []
    var snapshotTree: [VMSnapshotTreeNode] = []
    var currentSnapshotID: String?
    var selectedBackend: VMSnapshotBackend = .apfsClone
    var newSnapshotName: String = ""
    var snapshotBeforeRestore = true
    var isWorking = false
    var message: String = ""
    var searchText: String = ""

    var filteredTree: [VMSnapshotTreeNode] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return snapshotTree }
        func filter(_ node: VMSnapshotTreeNode) -> VMSnapshotTreeNode? {
            let children = node.children?.compactMap(filter)
            let matches = node.snapshot.name.localizedCaseInsensitiveContains(query)
                || node.snapshot.displayDate.localizedCaseInsensitiveContains(query)
            guard matches || !(children?.isEmpty ?? true) else { return nil }
            return VMSnapshotTreeNode(snapshot: node.snapshot, children: children?.isEmpty == true ? nil : children)
        }
        return snapshotTree.compactMap(filter)
    }

    var totalSnapshotSize: String {
        let total = snapshots.reduce(UInt64(0)) { $0 + ($1.totalSize ?? 0) }
        return ByteCountFormatter.string(fromByteCount: Int64(total), countStyle: .file)
    }

    init(rootPath: URL) {
        self.rootPath = rootPath
        reload()
    }

    func reload() {
        snapshots = VMSnapshotManager.listSnapshots(vmRootPath: rootPath)
        snapshotTree = VMSnapshotManager.snapshotTree(vmRootPath: rootPath)
        currentSnapshotID = VMSnapshotManager.currentSnapshotID(vmRootPath: rootPath)
        selectedBackend = VMSnapshotManager.selectedBackend(vmRootPath: rootPath)
    }

    private func notifySnapshotsChanged() {
        // snapshot count on the machine card and possibly config.json changed
        NotificationCenter.default.post(name: AppConfigManager.newVMChangedNotification, object: nil)
    }

    func createSnapshot() {
        var name = newSnapshotName.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty {
            name = VMSnapshotManager.defaultSnapshotName()
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
                    self.notifySnapshotsChanged()
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
        let keepCurrentState = snapshotBeforeRestore
        Task.detached {
            // optionally keep the current state as its own snapshot, so a
            // restore is never a one way door
            if keepCurrentState {
                let safetyName = "Before restoring \"\(snapshot.name)\""
                let safetyResult = VMSnapshotManager.createSnapshot(vmRootPath: rootPath, name: safetyName)
                if case let .failure(error) = safetyResult {
                    await MainActor.run {
                        self.isWorking = false
                        self.message = "Restore cancelled, could not snapshot the current state : \(error)"
                        self.reload()
                    }
                    return
                }
            }

            let result = VMSnapshotManager.restoreSnapshot(vmRootPath: rootPath, snapshot: snapshot)
            await MainActor.run {
                self.isWorking = false
                switch result {
                case .success:
                    self.message = "Snapshot \"\(snapshot.name)\" restored"
                    self.notifySnapshotsChanged()
                case .failure(let error):
                    self.message = error
                }
                self.reload()
            }
        }
    }

    func renameSnapshot(_ snapshot: VMSnapshotModel, newName: String) {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty || name == snapshot.name {
            return
        }
        let rootPath = self.rootPath
        Task.detached {
            let result = VMSnapshotManager.renameSnapshot(vmRootPath: rootPath, snapshot: snapshot, newName: name)
            await MainActor.run {
                if case let .failure(error) = result {
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
                    self.notifySnapshotsChanged()
                case .failure(let error):
                    self.message = error
                }
                self.reload()
            }
        }
    }

    func toggleProtection(_ snapshot: VMSnapshotModel) {
        let result = VMSnapshotManager.setSnapshotProtected(
            vmRootPath: rootPath,
            snapshot: snapshot,
            isProtected: !snapshot.isProtected
        )
        if case let .failure(error) = result { message = error }
        reload()
    }

    func auditSnapshots() {
        isWorking = true
        message = "Auditing snapshot integrity ..."
        let rootPath = self.rootPath
        let snapshots = self.snapshots
        Task.detached {
            let reports = snapshots.map { ($0, VMSnapshotManager.auditSnapshot(vmRootPath: rootPath, snapshot: $0)) }
            let invalid = reports.filter { !$0.1.isValid }
            let warningCount = reports.reduce(0) { $0 + $1.1.warnings.count }
            await MainActor.run {
                self.isWorking = false
                if invalid.isEmpty {
                    self.message = warningCount == 0
                        ? "All \(reports.count) snapshots passed integrity checks"
                        : "All snapshots are structurally valid; \(warningCount) legacy warning(s)"
                } else {
                    let names = invalid.map { $0.0.name }.joined(separator: ", ")
                    self.message = "\(invalid.count) snapshot(s) failed integrity checks: \(names)"
                }
            }
        }
    }
}


struct MachineSnapshotRowView: View {
    let snapshot: VMSnapshotModel
    let parentName: String?
    let isCurrent: Bool
    let hasChildren: Bool
    let disableActions: Bool
    let disableRestore: Bool
    let onRestore: () -> Void
    let onRename: () -> Void
    let onToggleProtection: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack {
            Image(systemName: "camera")
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(snapshot.name)
                    if snapshot.isProtected {
                        Image(systemName: "lock.fill")
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Protected")
                    }
                    if isCurrent {
                        Text("Current branch")
                            .font(.caption2)
                            .foregroundStyle(.blue)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.blue.opacity(0.12), in: Capsule())
                    }
                }
                HStack(spacing: 4) {
                    if let parentName {
                        Text("From \(parentName)")
                        Text("·")
                    } else {
                        Text("Root")
                        Text("·")
                    }
                    Text(snapshot.displayRelativeDate)
                    Text("·")
                    Text(snapshot.displayDate)
                    Text("·")
                    Text(snapshot.backend == .diskImageKitLayered ? "ASIF layers" : "APFS clone")
                    if !snapshot.displaySize.isEmpty {
                        Text("·")
                        Text(snapshot.displaySize)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()

            Button {
                onRestore()
            } label: {
                Image(systemName: "arrow.counterclockwise.circle")
                Text("Restore")
            }
            .disabled(disableActions || disableRestore)

            Button {
                onRename()
            } label: {
                Image(systemName: "pencil")
            }
            .disabled(disableActions)
            .help("Rename")

            Button {
                onToggleProtection()
            } label: {
                Image(systemName: snapshot.isProtected ? "lock.open" : "lock")
            }
            .disabled(disableActions)
            .help(snapshot.isProtected ? "Unprotect" : "Protect from deletion")

            Button {
                onDelete()
            } label: {
                Image(systemName: "trash")
            }
            .disabled(disableActions)
            .disabled(hasChildren || snapshot.isProtected)
            .help(snapshot.isProtected ? "Unprotect before deleting" : (hasChildren ? "Delete child snapshots first" : "Delete"))
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button {
                onRestore()
            } label: {
                Image(systemName: "arrow.counterclockwise.circle")
                Text("Restore")
            }
            .disabled(disableActions || disableRestore)

            Button {
                onRename()
            } label: {
                Image(systemName: "pencil")
                Text("Rename")
            }
            .disabled(disableActions)

            Button(snapshot.isProtected ? "Unprotect" : "Protect") {
                onToggleProtection()
            }
            .disabled(disableActions)

            Button {
                onDelete()
            } label: {
                Image(systemName: "trash")
                Text("Delete")
            }
            .disabled(disableActions)
            .disabled(hasChildren || snapshot.isProtected)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(isCurrent ? "\(snapshot.name), current branch" : snapshot.name)
        .accessibilityIdentifier("snapshot-row-\(snapshot.id)")
    }
}


struct MachineSnapshotsView: View {
    @Environment(\.dismiss) private var dismiss

    let machineName: String
    @State private var state: MachineSnapshotsViewStateObject
    @State private var runningRegistry = VMRunningRegistry.shared

    @State private var restoringSnapshot: VMSnapshotModel?
    @State private var deletingSnapshot: VMSnapshotModel?

    init(machineName: String, rootPath: URL) {
        self.machineName = machineName
        _state = State(initialValue: MachineSnapshotsViewStateObject(rootPath: rootPath))
    }

    var isMachineRunning: Bool {
        runningRegistry.isRunning(rootPath: state.rootPath)
    }

    var body: some View {
        @Bindable var state = state
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "camera.on.rectangle")
                Text("Snapshots - \(machineName)")
                    .fontWeight(.bold)
                Spacer()
            }

            if isMachineRunning {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("The virtual machine is running. Shut it down before creating or restoring snapshots.")
                        .foregroundStyle(.orange)
                    Spacer()
                }
                .font(.caption)
            } else {
                HStack {
                    Text("Snapshots form a history tree. Restore an earlier snapshot and create a new one to start another branch.")
                    Spacer()
                Label(
                        state.selectedBackend == .diskImageKitLayered ? "ASIF layered" : "APFS clone",
                        systemImage: state.selectedBackend == .diskImageKitLayered ? "square.stack.3d.up" : "doc.on.doc"
                )
                .foregroundStyle(.secondary)
                Text("· \(state.snapshots.count) snapshots · \(state.totalSnapshotSize)")
                    .foregroundStyle(.secondary)
                }
                .font(.caption)
            }

            HStack {
                TextField(VMSnapshotManager.defaultSnapshotName(), text: $state.newSnapshotName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        if !state.isWorking && !isMachineRunning {
                            state.createSnapshot()
                        }
                    }
                Button {
                    state.createSnapshot()
                } label: {
                    Image(systemName: "plus.circle")
                    Text("Create Snapshot")
                }
                .disabled(state.isWorking || isMachineRunning)
                Button {
                    state.auditSnapshots()
                } label: {
                    Image(systemName: "checkmark.shield")
                    Text("Audit")
                }
                .disabled(state.isWorking || state.snapshots.isEmpty)
            }

            if state.snapshots.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "camera.on.rectangle")
                        .font(.system(size: 36))
                        .foregroundStyle(.secondary)
                    Text("No snapshots yet")
                        .foregroundStyle(.secondary)
                    Text(state.selectedBackend == .diskImageKitLayered
                         ? "Snapshots use macOS 27 ASIF overlay layers and are stored inside the machine bundle."
                         : "Snapshots are stored inside the machine bundle and use APFS copy-on-write when available.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 380)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                let snapshotsByID = Dictionary(uniqueKeysWithValues: state.snapshots.map { ($0.id, $0) })
                List {
                    OutlineGroup(state.filteredTree, children: \.children) { node in
                        MachineSnapshotRowView(
                            snapshot: node.snapshot,
                            parentName: node.snapshot.parentSnapshotID.flatMap { snapshotsByID[$0]?.name },
                            isCurrent: node.snapshot.id == state.currentSnapshotID,
                            hasChildren: !(node.children?.isEmpty ?? true),
                            disableActions: state.isWorking,
                            disableRestore: isMachineRunning,
                            onRestore: {
                                restoringSnapshot = node.snapshot
                            },
                            onRename: {
                                renameSnapshot(node.snapshot)
                            },
                            onToggleProtection: {
                                state.toggleProtection(node.snapshot)
                            },
                            onDelete: {
                                deletingSnapshot = node.snapshot
                            }
                        )
                    }
                }
                .searchable(text: $state.searchText, prompt: "Search snapshots")
            }

            Toggle(isOn: $state.snapshotBeforeRestore) {
                Text("Keep the current state as a snapshot before restoring")
                    .font(.caption)
            }
            .toggleStyle(.checkbox)

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
                    dismiss()
                } label: {
                    Text("Close")
                }
            }
        }
        .padding()
        .frame(width: 600, height: 460)
        .confirmationDialog(
            "Restore snapshot \"\(restoringSnapshot?.name ?? "")\" ?",
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
        } message: {
            if state.snapshotBeforeRestore {
                Text("The current state will be kept as a new snapshot first.")
            } else {
                Text("The current machine state will be replaced and lost.")
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

    func renameSnapshot(_ snapshot: VMSnapshotModel) {
        MacKitUtil.inputBox(title: "Rename Snapshot", message: snapshot.name, placeholder: "New name") { inputText in
            state.renameSnapshot(snapshot, newName: inputText)
        }
    }
}

#endif
