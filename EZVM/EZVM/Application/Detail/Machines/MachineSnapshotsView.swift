//
//  MachineSnapshotsView.swift
//  EZVM
//
//  Created by everettjf on 2026/8/18.
//

import SwiftUI
import Observation

#if arch(arm64)

enum MachineSnapshotMessageTone: Equatable {
    case neutral
    case working
    case success
    case warning
    case failure
}

@MainActor
@Observable
class MachineSnapshotsViewStateObject {
    let rootPath: URL

    var snapshots: [VMSnapshotModel] = []
    var snapshotTree: [VMSnapshotTreeNode] = []
    var currentSnapshotID: String?
    var maximumASIFLayerDepth = 0
    var selectedBackend: VMSnapshotBackend = .apfsClone
    var newSnapshotName: String = ""
    var snapshotBeforeRestore = true
    var isWorking = false
    var message: String = ""
    var messageTone: MachineSnapshotMessageTone = .neutral
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
        maximumASIFLayerDepth = VMSnapshotManager.maximumASIFLayerDepth(vmRootPath: rootPath)
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

        begin("Creating snapshot…")
        let rootPath = self.rootPath
        Task.detached {
            let result = VMSnapshotManager.createSnapshot(vmRootPath: rootPath, name: name)
            await MainActor.run {
                switch result {
                case .success(let model):
                    self.succeed("Snapshot \"\(model.name)\" created")
                    self.newSnapshotName = ""
                    self.notifySnapshotsChanged()
                case .failure(let error):
                    self.fail(error)
                }
                self.reload()
            }
        }
    }

    func restoreSnapshot(_ snapshot: VMSnapshotModel) {
        begin("Restoring snapshot \"\(snapshot.name)\"…")
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
                        self.fail("Restore cancelled because EZVM could not snapshot the current state: \(error)")
                        self.reload()
                    }
                    return
                }
            }

            let result = VMSnapshotManager.restoreSnapshot(vmRootPath: rootPath, snapshot: snapshot)
            await MainActor.run {
                switch result {
                case .success:
                    self.succeed("Snapshot \"\(snapshot.name)\" restored")
                    self.notifySnapshotsChanged()
                case .failure(let error):
                    self.fail(error)
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
        begin("Renaming snapshot \"\(snapshot.name)\"…")
        let rootPath = self.rootPath
        Task.detached {
            let result = VMSnapshotManager.renameSnapshot(vmRootPath: rootPath, snapshot: snapshot, newName: name)
            await MainActor.run {
                switch result {
                case .success:
                    self.succeed("Snapshot renamed to \"\(name)\"")
                    self.notifySnapshotsChanged()
                case .failure(let error):
                    self.fail(error)
                }
                self.reload()
            }
        }
    }

    func deleteSnapshot(_ snapshot: VMSnapshotModel) {
        begin("Deleting snapshot \"\(snapshot.name)\"…")
        let rootPath = self.rootPath
        Task.detached {
            let result = VMSnapshotManager.deleteSnapshot(vmRootPath: rootPath, snapshot: snapshot)
            await MainActor.run {
                switch result {
                case .success:
                    self.succeed("Snapshot \"\(snapshot.name)\" deleted")
                    self.notifySnapshotsChanged()
                case .failure(let error):
                    self.fail(error)
                }
                self.reload()
            }
        }
    }

    func toggleProtection(_ snapshot: VMSnapshotModel) {
        let shouldProtect = !snapshot.isProtected
        begin("\(shouldProtect ? "Protecting" : "Unprotecting") snapshot \"\(snapshot.name)\"…")
        let rootPath = self.rootPath
        Task.detached {
            let result = VMSnapshotManager.setSnapshotProtected(
                vmRootPath: rootPath,
                snapshot: snapshot,
                isProtected: shouldProtect
            )
            await MainActor.run {
                switch result {
                case .success:
                    self.succeed(
                        shouldProtect
                            ? "Snapshot \"\(snapshot.name)\" protected from deletion"
                            : "Snapshot \"\(snapshot.name)\" can now be deleted"
                    )
                    self.notifySnapshotsChanged()
                case .failure(let error):
                    self.fail(error)
                }
                self.reload()
            }
        }
    }

    func auditSnapshots() {
        begin("Auditing snapshot integrity…")
        let rootPath = self.rootPath
        let snapshots = self.snapshots
        Task.detached {
            let reports = snapshots.map { ($0, VMSnapshotManager.auditSnapshot(vmRootPath: rootPath, snapshot: $0)) }
            let invalid = reports.filter { !$0.1.isValid }
            let warningCount = reports.reduce(0) { $0 + $1.1.warnings.count }
            await MainActor.run {
                if invalid.isEmpty {
                    if warningCount == 0 {
                        self.succeed("All \(reports.count) snapshots passed integrity checks")
                    } else {
                        self.warn("All snapshots are structurally valid; \(warningCount) warning(s)")
                    }
                } else {
                    let names = invalid.map { $0.0.name }.joined(separator: ", ")
                    self.fail("\(invalid.count) snapshot(s) failed integrity checks: \(names)")
                }
            }
        }
    }

    private func begin(_ message: String) {
        isWorking = true
        self.message = message
        messageTone = .working
    }

    private func succeed(_ message: String) {
        isWorking = false
        self.message = message
        messageTone = .success
    }

    private func warn(_ message: String) {
        isWorking = false
        self.message = message
        messageTone = .warning
    }

    private func fail(_ message: String) {
        isWorking = false
        self.message = message
        messageTone = .failure
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
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "camera.fill")
                    .font(.title3)
                    .foregroundStyle(isCurrent ? .blue : .secondary)
                    .frame(width: 34, height: 34)
                    .background(
                        (isCurrent ? Color.blue : Color.secondary).opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                    )
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 7) {
                        Text(snapshot.name)
                            .font(.headline)
                            .lineLimit(1)
                        if snapshot.isProtected {
                            Image(systemName: "lock.fill")
                                .foregroundStyle(.secondary)
                                .accessibilityLabel("Protected")
                        }
                        if isCurrent {
                            Text("Current branch")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.blue)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(.blue.opacity(0.12), in: Capsule())
                        }
                    }

                    HStack(spacing: 5) {
                        Image(systemName: parentName == nil ? "point.topleft.down.to.point.bottomright.curvepath" : "arrow.turn.down.right")
                            .accessibilityHidden(true)
                        Text(parentName.map { "From \($0)" } ?? "Root snapshot")
                            .lineLimit(1)
                        Text("·")
                        Text(snapshot.displayRelativeDate)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)

                Button {
                    onRestore()
                } label: {
                    Label("Restore", systemImage: "arrow.counterclockwise.circle")
                }
                .buttonStyle(.borderedProminent)
                .disabled(disableActions || disableRestore)
            }

            HStack(spacing: 6) {
                Label(snapshot.displayDate, systemImage: "calendar")
                    .fixedSize(horizontal: true, vertical: false)
                Text("·")
                Label(
                    snapshot.backend == .diskImageKitLayered ? "ASIF layers" : "APFS clone",
                    systemImage: snapshot.backend == .diskImageKitLayered ? "square.stack.3d.up" : "doc.on.doc"
                )
                if !snapshot.displaySize.isEmpty {
                    Text("·")
                    Label(snapshot.displaySize, systemImage: "internaldrive")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .labelStyle(.titleAndIcon)

            Divider()

            HStack(spacing: 8) {
                Label(
                    snapshot.isProtected ? "Protected from deletion" : (hasChildren ? "Has child snapshots" : "Ready"),
                    systemImage: snapshot.isProtected ? "lock.shield.fill" : (hasChildren ? "arrow.triangle.branch" : "checkmark.circle")
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                Spacer()

                Button("Rename", systemImage: "pencil", action: onRename)
                    .disabled(disableActions)
                    .help("Rename")

                Button(snapshot.isProtected ? "Unprotect" : "Protect", systemImage: snapshot.isProtected ? "lock.open" : "lock", action: onToggleProtection)
                    .disabled(disableActions)
                    .help(snapshot.isProtected ? "Unprotect" : "Protect from deletion")

                Button("Delete", systemImage: "trash", role: .destructive, action: onDelete)
                    .labelStyle(.iconOnly)
                    .disabled(disableActions || hasChildren || snapshot.isProtected)
                    .help(snapshot.isProtected ? "Unprotect before deleting" : (hasChildren ? "Delete child snapshots first" : "Delete"))
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(isCurrent ? Color.blue.opacity(0.55) : Color.secondary.opacity(0.2), lineWidth: isCurrent ? 1.5 : 1)
        }
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
            HStack(spacing: 10) {
                Image(systemName: "camera.on.rectangle")
                    .font(.title2)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Snapshots").font(.title2.weight(.semibold))
                    Text(machineName).font(.caption).foregroundStyle(.secondary)
                }
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
                if state.selectedBackend == .diskImageKitLayered,
                   state.maximumASIFLayerDepth > 0 {
                    Text("· \(state.maximumASIFLayerDepth)-layer depth")
                        .foregroundStyle(
                            state.maximumASIFLayerDepth >= VMSnapshotManager.recommendedMaximumASIFLayerDepth
                                ? .orange
                                : .secondary
                        )
                        .help(
                            state.maximumASIFLayerDepth >= VMSnapshotManager.recommendedMaximumASIFLayerDepth
                                ? "This snapshot chain is deep. Consolidate the machine before creating many more snapshots."
                                : "Maximum ASIF overlay depth across the active machine and saved snapshots."
                        )
                }
                }
                .font(.caption)
            }

            HStack {
                TextField("Snapshot name", text: $state.newSnapshotName, prompt: Text(VMSnapshotManager.defaultSnapshotName()))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        if !state.isWorking && !isMachineRunning {
                            state.createSnapshot()
                        }
                    }
                Button {
                    state.createSnapshot()
                } label: { Label("Create Snapshot", systemImage: "plus.circle") }
                .buttonStyle(.borderedProminent)
                .disabled(state.isWorking || isMachineRunning)
                Button {
                    state.auditSnapshots()
                } label: { Label("Audit", systemImage: "checkmark.shield") }
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
                        .listRowInsets(EdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .overlay {
                    if state.filteredTree.isEmpty, !state.searchText.isEmpty {
                        ContentUnavailableView.search(text: state.searchText)
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
                if !state.message.isEmpty {
                    Label(state.message, systemImage: messageSymbol(for: state.messageTone))
                        .font(.caption)
                        .foregroundStyle(messageColor(for: state.messageTone))
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Text("Close")
                }
            }
        }
        .padding()
        .frame(minWidth: 680, idealWidth: 760, minHeight: 520, idealHeight: 600)
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

    private func messageSymbol(for tone: MachineSnapshotMessageTone) -> String {
        switch tone {
        case .neutral: return "info.circle"
        case .working: return "clock"
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .failure: return "xmark.octagon.fill"
        }
    }

    private func messageColor(for tone: MachineSnapshotMessageTone) -> Color {
        switch tone {
        case .neutral: return .secondary
        case .working: return .secondary
        case .success: return .green
        case .warning: return .orange
        case .failure: return .red
        }
    }
}

#endif
