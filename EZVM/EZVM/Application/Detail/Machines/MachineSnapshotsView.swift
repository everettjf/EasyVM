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

struct MachineSnapshotRestoreReview: Identifiable {
    let snapshot: VMSnapshotModel
    let keepCurrentState: Bool
    let estimate: VMSnapshotRestoreStorageEstimate

    var id: String { snapshot.id }
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
    var workingDetail: String = ""
    var operationProgress: VMSnapshotOperationProgress?
    var isCancellationRequested = false
    var cleanupPreview: VMSnapshotMaintenanceReport?
    var messageTone: MachineSnapshotMessageTone = .neutral
    var searchText: String = ""
    var restoreReview: MachineSnapshotRestoreReview?
    var isPreparingRestoreReview = false
    @ObservationIgnored private var operationControl: VMSnapshotOperationControl?
    @ObservationIgnored private var restoreReviewRequestID: UUID?

    var isBusy: Bool { isWorking || isPreparingRestoreReview }

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

        let control = begin(
            "Preparing snapshot…",
            detail: "Checking disk space and preserving the current machine files."
        )
        let rootPath = self.rootPath
        Task.detached {
            let result = VMSnapshotManager.createSnapshot(
                vmRootPath: rootPath,
                name: name,
                operationControl: control
            ) { update in
                Task { @MainActor in self.receive(update, from: control) }
            }
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

    func prepareRestoreReview(_ snapshot: VMSnapshotModel) {
        guard !isBusy else { return }
        let requestID = UUID()
        restoreReviewRequestID = requestID
        isPreparingRestoreReview = true
        restoreReview = nil
        message = "Estimating restore storage…"
        workingDetail = "Inspecting the target snapshot and current machine without changing either one."
        messageTone = .working
        let rootPath = self.rootPath
        let keepCurrentState = snapshotBeforeRestore
        Task.detached {
            let result = VMSnapshotManager.restoreStorageEstimate(
                vmRootPath: rootPath,
                snapshot: snapshot,
                keepCurrentState: keepCurrentState
            )
            await MainActor.run {
                guard self.restoreReviewRequestID == requestID else { return }
                self.restoreReviewRequestID = nil
                self.isPreparingRestoreReview = false
                self.workingDetail = ""
                switch result {
                case .success(let estimate):
                    self.restoreReview = MachineSnapshotRestoreReview(
                        snapshot: snapshot,
                        keepCurrentState: keepCurrentState,
                        estimate: estimate
                    )
                    self.message = "Restore review ready"
                    self.messageTone = estimate.hasEnoughSpace == false ? .warning : .neutral
                case .failure(let error):
                    self.fail("Restore cannot be prepared: \(error)")
                }
            }
        }
    }

    func restoreSnapshot(_ snapshot: VMSnapshotModel, keepCurrentState: Bool) {
        let control = begin(
            keepCurrentState ? "Saving the current state first…" : "Preparing restore…",
            detail: keepCurrentState
                ? "EZVM will keep a recovery point before replacing the machine state."
                : "Checking snapshot integrity and available disk space."
        )
        let rootPath = self.rootPath
        Task.detached {
            let estimateResult = VMSnapshotManager.restoreStorageEstimate(
                vmRootPath: rootPath,
                snapshot: snapshot,
                keepCurrentState: keepCurrentState
            )
            switch estimateResult {
            case .success(let estimate) where estimate.hasEnoughSpace == false:
                await MainActor.run {
                    self.fail("Restore cancelled before any change because the operation needs \(self.displaySize(estimate.requiredAvailableBytes)) available, but this volume has \(self.displaySize(estimate.availableBytes ?? 0)).")
                }
                return
            case .failure(let error):
                await MainActor.run {
                    self.fail("Restore cancelled before any change: \(error)")
                }
                return
            case .success:
                break
            }

            // optionally keep the current state as its own snapshot, so a
            // restore is never a one way door
            if keepCurrentState {
                let safetyName = "Before restoring \"\(snapshot.name)\""
                let safetyResult = VMSnapshotManager.createSnapshot(
                    vmRootPath: rootPath,
                    name: safetyName,
                    operationControl: control
                ) { update in
                    Task { @MainActor in self.receive(update, from: control) }
                }
                if case let .failure(error) = safetyResult {
                    await MainActor.run {
                        self.fail("Restore cancelled because EZVM could not snapshot the current state: \(error)")
                        self.reload()
                    }
                    return
                }
            }

            await MainActor.run {
                self.updateWorking(
                    "Restoring snapshot \"\(snapshot.name)\"…",
                    detail: "Installing the verified snapshot transaction. This window will unlock when the machine is safe to use."
                )
            }

            let result = VMSnapshotManager.restoreSnapshot(
                vmRootPath: rootPath,
                snapshot: snapshot,
                operationControl: control
            ) { update in
                Task { @MainActor in self.receive(update, from: control) }
            }
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
        begin("Renaming snapshot \"\(snapshot.name)\"…", detail: "Updating snapshot metadata safely.")
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
        begin("Deleting snapshot \"\(snapshot.name)\"…", detail: "Removing only data that is no longer referenced.")
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
        begin(
            "\(shouldProtect ? "Protecting" : "Unprotecting") snapshot \"\(snapshot.name)\"…",
            detail: "Updating snapshot protection metadata safely."
        )
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
        let control = begin(
            "Auditing snapshot integrity…",
            detail: "Validating metadata, files, and every ASIF layer stack."
        )
        let rootPath = self.rootPath
        let snapshots = self.snapshots
        Task.detached {
            var reports: [(VMSnapshotModel, VMSnapshotIntegrityReport)] = []
            let total = UInt64(snapshots.count)
            for (index, snapshot) in snapshots.enumerated() {
                if control.isCancellationRequested {
                    await MainActor.run {
                        self.cancelled("Snapshot audit cancelled")
                    }
                    return
                }
                let startingUpdate = VMSnapshotOperationProgress(
                    phase: .verifying,
                    completedUnitCount: UInt64(index),
                    totalUnitCount: total,
                    unit: .items,
                    canCancel: true
                )
                await MainActor.run { self.receive(startingUpdate, from: control) }
                reports.append((snapshot, VMSnapshotManager.auditSnapshot(vmRootPath: rootPath, snapshot: snapshot)))
                if control.isCancellationRequested {
                    await MainActor.run {
                        self.cancelled("Snapshot audit cancelled")
                    }
                    return
                }
                let completedUpdate = VMSnapshotOperationProgress(
                    phase: .verifying,
                    completedUnitCount: UInt64(index + 1),
                    totalUnitCount: total,
                    unit: .items,
                    canCancel: true
                )
                await MainActor.run { self.receive(completedUpdate, from: control) }
            }
            let finishedUpdate = VMSnapshotOperationProgress(
                phase: .finishing,
                completedUnitCount: total,
                totalUnitCount: total,
                unit: .items,
                canCancel: false
            )
            await MainActor.run { self.receive(finishedUpdate, from: control) }
            let invalid = reports.filter { !$0.1.isValid }
            let warningCount = reports.reduce(0) { $0 + $1.1.warnings.count }
            let reportCount = reports.count
            await MainActor.run {
                if invalid.isEmpty {
                    if warningCount == 0 {
                        self.succeed("All \(reportCount) snapshots passed integrity checks")
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

    func previewLayerCleanup() {
        cleanupPreview = nil
        begin(
            "Inspecting snapshot storage…",
            detail: "Building a read-only reference map before offering any cleanup."
        )
        let rootPath = self.rootPath
        Task.detached {
            let report = VMSnapshotManager.snapshotMaintenanceReport(vmRootPath: rootPath)
            await MainActor.run {
                if !report.issues.isEmpty {
                    self.fail(report.issues.joined(separator: " "))
                } else if report.removableLayers.isEmpty {
                    self.succeed("No unreferenced ASIF layers were found")
                } else {
                    self.succeed(
                        "Found \(report.removableLayers.count) unreferenced layer(s) using \(self.displaySize(report.removableAllocatedSize))"
                    )
                    self.cleanupPreview = report
                }
            }
        }
    }

    func cleanupUnreferencedLayers() {
        cleanupPreview = nil
        begin(
            "Cleaning snapshot storage…",
            detail: "Moving verified orphan layers through a recoverable cleanup transaction."
        )
        let rootPath = self.rootPath
        Task.detached {
            let result = VMSnapshotManager.cleanupUnreferencedLayers(vmRootPath: rootPath)
            await MainActor.run {
                switch result {
                case .success(let cleanup):
                    if cleanup.removedLayerCount == 0 {
                        self.succeed("Snapshot storage is already clean")
                    } else {
                        self.succeed(
                            "Removed \(cleanup.removedLayerCount) unreferenced layer(s) and reclaimed \(self.displaySize(cleanup.reclaimedAllocatedSize))"
                        )
                        self.notifySnapshotsChanged()
                    }
                case .failure(let error):
                    self.fail(error)
                }
                self.reload()
            }
        }
    }

    @discardableResult
    private func begin(_ message: String, detail: String) -> VMSnapshotOperationControl {
        let control = VMSnapshotOperationControl()
        operationControl = control
        operationProgress = nil
        isCancellationRequested = false
        isWorking = true
        self.message = message
        workingDetail = detail
        messageTone = .working
        return control
    }

    private func updateWorking(_ message: String, detail: String) {
        guard isWorking else { return }
        self.message = message
        workingDetail = detail
        messageTone = .working
    }

    private func succeed(_ message: String) {
        isWorking = false
        operationControl = nil
        operationProgress = nil
        isCancellationRequested = false
        self.message = message
        workingDetail = ""
        messageTone = .success
    }

    private func warn(_ message: String) {
        isWorking = false
        operationControl = nil
        operationProgress = nil
        isCancellationRequested = false
        self.message = message
        workingDetail = ""
        messageTone = .warning
    }

    private func fail(_ message: String) {
        isWorking = false
        operationControl = nil
        operationProgress = nil
        isCancellationRequested = false
        self.message = message
        workingDetail = ""
        messageTone = .failure
    }

    func cancelOperation() {
        guard isWorking,
              operationProgress?.canCancel == true,
              !isCancellationRequested else { return }
        isCancellationRequested = true
        operationControl?.cancel()
        workingDetail = "Cancellation requested. EZVM will stop at the next safe boundary."
    }

    private func cancelled(_ message: String) {
        isWorking = false
        operationControl = nil
        operationProgress = nil
        isCancellationRequested = false
        self.message = message
        workingDetail = ""
        messageTone = .neutral
    }

    private func receive(_ update: VMSnapshotOperationProgress, from control: VMSnapshotOperationControl) {
        guard isWorking, operationControl === control else { return }
        operationProgress = update
        if !isCancellationRequested {
            workingDetail = progressDescription(update)
        }
    }

    private func progressDescription(_ update: VMSnapshotOperationProgress) -> String {
        let phase: String = switch update.phase {
        case .preparing: "Preparing and checking available space"
        case .copying: "Copying machine data"
        case .verifying: "Verifying snapshot integrity"
        case .committing: "Installing the verified transaction"
        case .finishing: "Finishing safely"
        }
        guard update.totalUnitCount > 0 else { return phase }
        switch update.unit {
        case .bytes:
            let completed = ByteCountFormatter.string(fromByteCount: Int64(clamping: update.completedUnitCount), countStyle: .file)
            let total = ByteCountFormatter.string(fromByteCount: Int64(clamping: update.totalUnitCount), countStyle: .file)
            return "\(phase) · \(completed) of \(total)"
        case .items:
            return "\(phase) · \(update.completedUnitCount) of \(update.totalUnitCount) snapshots"
        }
    }

    private func displaySize(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
    }

    private func displaySize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, bytes), countStyle: .file)
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
                        if !state.isBusy && !isMachineRunning {
                            state.createSnapshot()
                        }
                    }
                Button {
                    state.createSnapshot()
                } label: { Label("Create Snapshot", systemImage: "plus.circle") }
                .buttonStyle(.borderedProminent)
                .disabled(state.isBusy || isMachineRunning)
                Button {
                    state.auditSnapshots()
                } label: { Label("Audit", systemImage: "checkmark.shield") }
                .disabled(state.isBusy || state.snapshots.isEmpty)
                Button {
                    state.previewLayerCleanup()
                } label: { Label("Clean Up…", systemImage: "sparkles") }
                .disabled(state.isBusy || isMachineRunning)
                .help("Preview unreferenced ASIF layers before removing anything.")
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
                            disableActions: state.isBusy,
                            disableRestore: isMachineRunning,
                            onRestore: {
                                state.prepareRestoreReview(node.snapshot)
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
                    VStack(alignment: .leading, spacing: 5) {
                        Text(state.message)
                            .font(.caption.weight(.medium))
                        Text(state.workingDetail)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        if let fraction = state.operationProgress?.fractionCompleted {
                            ProgressView(value: fraction)
                                .frame(maxWidth: 280)
                        } else {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                    .accessibilityLabel(state.message)
                    .accessibilityValue(state.workingDetail)
                }
                if state.isPreparingRestoreReview {
                    HStack(spacing: 7) {
                        ProgressView()
                            .controlSize(.small)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(state.message)
                                .font(.caption.weight(.medium))
                            Text(state.workingDetail)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
                if !state.isBusy, !state.message.isEmpty {
                    Label(state.message, systemImage: messageSymbol(for: state.messageTone))
                        .font(.caption)
                        .foregroundStyle(messageColor(for: state.messageTone))
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                Spacer()
                if state.isWorking, state.operationProgress?.canCancel == true {
                    Button(state.isCancellationRequested ? "Cancelling…" : "Cancel") {
                        state.cancelOperation()
                    }
                    .disabled(state.isCancellationRequested)
                    .help("Stop at the next safe boundary before machine files are replaced.")
                } else if state.isWorking, state.operationProgress != nil {
                    Label("Finishing safely", systemImage: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("The snapshot transaction is finishing and can no longer be cancelled")
                }
                Button {
                    dismiss()
                } label: {
                    Text("Close")
                }
                .disabled(state.isBusy)
                .help(
                    state.isBusy
                        ? "Wait until the snapshot transaction finishes safely before closing this window."
                        : "Close Snapshots"
                )
            }
        }
        .padding()
        .frame(minWidth: 680, idealWidth: 760, minHeight: 520, idealHeight: 600)
        .interactiveDismissDisabled(state.isBusy)
        .sheet(item: $state.restoreReview) { review in
            MachineSnapshotRestoreReviewView(review: review)
                .environment(state)
        }
        .confirmationDialog(
            "Clean up unreferenced snapshot layers?",
            isPresented: Binding(
                get: { state.cleanupPreview != nil },
                set: { if !$0 { state.cleanupPreview = nil } }
            )
        ) {
            if let preview = state.cleanupPreview {
                Button(
                    "Remove \(preview.removableLayers.count) Layer(s)",
                    role: .destructive
                ) {
                    state.cleanupUnreferencedLayers()
                }
                .disabled(isMachineRunning || state.isBusy)
            }
            Button("Cancel", role: .cancel) {
                state.cleanupPreview = nil
            }
        } message: {
            if let preview = state.cleanupPreview {
                Text(
                    "EZVM verified that no active branch or saved snapshot references these layers. " +
                    "This will reclaim \(ByteCountFormatter.string(fromByteCount: Int64(clamping: preview.removableAllocatedSize), countStyle: .file)). " +
                    "Unknown files and \(preview.retainedLayerCount) referenced or unmanaged item(s) will remain untouched."
                )
            }
        }
        .confirmationDialog(
            "Delete snapshot \"\(deletingSnapshot?.name ?? "")\"? This cannot be undone.",
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

private struct MachineSnapshotRestoreReviewView: View {
    @Environment(MachineSnapshotsViewStateObject.self) private var state
    @Environment(\.dismiss) private var dismiss

    let review: MachineSnapshotRestoreReview

    private var estimate: VMSnapshotRestoreStorageEstimate { review.estimate }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: estimate.hasEnoughSpace == false ? "externaldrive.badge.exclamationmark" : "arrow.counterclockwise.circle.fill")
                    .font(.title)
                    .foregroundStyle(estimate.hasEnoughSpace == false ? Color.orange : Color.accentColor)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Review Restore")
                        .font(.title2.weight(.semibold))
                    Text(review.snapshot.name)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
            }

            GroupBox {
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 10) {
                    storageRow("Restore staging", value: displaySize(estimate.restoreStagingBytes))
                    if review.keepCurrentState {
                        storageRow("Safety snapshot", value: displaySize(estimate.safetySnapshotBytes))
                    }
                    storageRow("Safety reserve", value: displaySize(estimate.reserveBytes))
                    Divider().gridCellColumns(2)
                    storageRow("Required available", value: displaySize(estimate.requiredAvailableBytes), emphasized: true)
                    storageRow("Available now", value: estimate.availableBytes.map(displaySize) ?? "Not reported", emphasized: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            } label: {
                Label("Storage", systemImage: "internaldrive")
                    .font(.headline)
            }

            Label(statusMessage, systemImage: statusSymbol)
                .font(.callout)
                .foregroundStyle(statusColor)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityElement(children: .combine)

            Text(preservationMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()
            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Restore", systemImage: "arrow.counterclockwise") {
                    state.restoreSnapshot(
                        review.snapshot,
                        keepCurrentState: review.keepCurrentState
                    )
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(estimate.hasEnoughSpace == false)
                .keyboardShortcut(.defaultAction)
                .help(estimate.hasEnoughSpace == false ? "Free disk space before restoring." : "Begin the verified restore transaction.")
            }
        }
        .padding(24)
        .frame(minWidth: 500, idealWidth: 540)
    }

    private var statusMessage: String {
        switch estimate.hasEnoughSpace {
        case .some(true):
            "There is enough reported space. EZVM will verify capacity again before changing the machine."
        case .some(false):
            "Restore is unavailable. Free at least \(displaySize(missingBytes)) and try again."
        case .none:
            "macOS did not report available capacity. EZVM will check again before changing the machine."
        }
    }

    private var statusSymbol: String {
        switch estimate.hasEnoughSpace {
        case .some(true): "checkmark.circle.fill"
        case .some(false): "exclamationmark.triangle.fill"
        case .none: "questionmark.circle"
        }
    }

    private var statusColor: Color {
        switch estimate.hasEnoughSpace {
        case .some(true): .green
        case .some(false): .orange
        case .none: .secondary
        }
    }

    private var preservationMessage: String {
        if review.keepCurrentState {
            "EZVM will create a recovery snapshot before restoring. The estimate is conservative; APFS copy-on-write may use less physical space."
        } else {
            "The current machine state will be replaced and cannot be recovered unless it already exists in another snapshot."
        }
    }

    private var missingBytes: Int64 {
        estimate.requiredAvailableBytes - max(0, estimate.availableBytes ?? 0)
    }

    private func storageRow(_ title: String, value: String, emphasized: Bool = false) -> some View {
        GridRow {
            Text(title)
                .foregroundStyle(emphasized ? .primary : .secondary)
            Text(value)
                .fontWeight(emphasized ? .semibold : .regular)
                .monospacedDigit()
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
    }

    private func displaySize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, bytes), countStyle: .file)
    }
}

#endif
