//
//  VMSnapshotManager.swift
//  EasyVM
//
//  Created by everettjf on 2026/8/18.
//

import Foundation
#if canImport(DiskImageKit)
import DiskImageKit
#endif

enum VMSnapshotBackend: String, Codable, CaseIterable {
    /// FileManager.copyItem uses APFS clone-on-write when source and destination
    /// are on the same APFS volume, and safely falls back to a regular copy.
    case apfsClone
    /// An immutable ASIF base plus DiskImageKit overlay layers (macOS 27+).
    case diskImageKitLayered
}

struct VMSnapshotDiskLayer: Codable, Equatable {
    let baseImageName: String
    let layerPaths: [String]
}

/*
 File level snapshots for a virtual machine bundle.

 A snapshot is a copy of every file in the bundle (disk image, auxiliary
 storage, NVRAM, machine identifier, config ...) stored under
 <bundle>/Snapshots/<id>/files, plus a snapshot.json describing it.

 Copies are made with FileManager.copyItem, which clones files on APFS
 (copy-on-write), so taking a snapshot is fast and only consumes space as
 the disk image diverges afterwards.

 Restoring is transactional: the snapshot is cloned into a staging
 directory first, then swapped in with renames; any failure rolls the
 machine back to the state it was in before the restore started.

 Snapshots must be taken/restored while the virtual machine is shut down.
 */
struct VMSnapshotModel: Identifiable, Codable {
    let id: String
    var name: String
    let createdAt: Date
    // nil for root snapshots and metadata written by older versions
    let parentSnapshotID: String?
    // missing in metadata written by older versions
    let totalSize: UInt64?
    let backend: VMSnapshotBackend
    let diskLayers: [VMSnapshotDiskLayer]

    init(
        id: String,
        name: String,
        createdAt: Date,
        parentSnapshotID: String?,
        totalSize: UInt64?,
        backend: VMSnapshotBackend = .apfsClone,
        diskLayers: [VMSnapshotDiskLayer] = []
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.parentSnapshotID = parentSnapshotID
        self.totalSize = totalSize
        self.backend = backend
        self.diskLayers = diskLayers
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, createdAt, parentSnapshotID, totalSize, backend, diskLayers
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        parentSnapshotID = try container.decodeIfPresent(String.self, forKey: .parentSnapshotID)
        totalSize = try container.decodeIfPresent(UInt64.self, forKey: .totalSize)
        backend = try container.decodeIfPresent(VMSnapshotBackend.self, forKey: .backend) ?? .apfsClone
        diskLayers = try container.decodeIfPresent([VMSnapshotDiskLayer].self, forKey: .diskLayers) ?? []
    }

    var displayDate: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: createdAt)
    }

    var displayRelativeDate: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: createdAt, relativeTo: Date())
    }

    var displaySize: String {
        guard let totalSize = totalSize else {
            return ""
        }
        return ByteCountFormatter.string(fromByteCount: Int64(totalSize), countStyle: .file)
    }
}

struct VMSnapshotTreeNode: Identifiable {
    let snapshot: VMSnapshotModel
    let children: [VMSnapshotTreeNode]?

    var id: String { snapshot.id }
}


private struct VMSnapshotStoreState: Codable {
    var currentSnapshotID: String?
    var activeDiskLayers: [String: [String]]

    init(currentSnapshotID: String? = nil, activeDiskLayers: [String: [String]] = [:]) {
        self.currentSnapshotID = currentSnapshotID
        self.activeDiskLayers = activeDiskLayers
    }

    private enum CodingKeys: String, CodingKey {
        case currentSnapshotID, activeDiskLayers
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        currentSnapshotID = try container.decodeIfPresent(String.self, forKey: .currentSnapshotID)
        activeDiskLayers = try container.decodeIfPresent([String: [String]].self, forKey: .activeDiskLayers) ?? [:]
    }
}

private struct VMSnapshotVMConfiguration: Decodable {
    struct StorageDevice: Decodable {
        let type: String
        let imagePath: String
        let format: String?
    }

    let storageDevices: [StorageDevice]
}


class VMSnapshotManager {

    static let snapshotsDirectoryName = "Snapshots"
    private static let filesDirectoryName = "files"
    private static let metaFileName = "snapshot.json"
    private static let stateFileName = "state.json"
    private static let restoreStagingDirectoryName = ".restore-staging"
    private static let restoreBackupDirectoryName = ".restore-backup"

    static func snapshotsRootURL(vmRootPath: URL) -> URL {
        vmRootPath.appending(path: snapshotsDirectoryName)
    }

    private static func snapshotDirURL(vmRootPath: URL, snapshotId: String) -> URL {
        snapshotsRootURL(vmRootPath: vmRootPath).appending(path: snapshotId)
    }

    private static func snapshotFilesURL(vmRootPath: URL, snapshotId: String) -> URL {
        snapshotDirURL(vmRootPath: vmRootPath, snapshotId: snapshotId).appending(path: filesDirectoryName)
    }

    private static func snapshotMetaURL(vmRootPath: URL, snapshotId: String) -> URL {
        snapshotDirURL(vmRootPath: vmRootPath, snapshotId: snapshotId).appending(path: metaFileName)
    }

    private static func stateURL(vmRootPath: URL) -> URL {
        snapshotsRootURL(vmRootPath: vmRootPath).appending(path: stateFileName)
    }

    static func defaultSnapshotName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return "Snapshot \(formatter.string(from: Date()))"
    }

    // machine files are everything in the bundle except the Snapshots
    // directory itself and restore working directories
    private static func listMachineFileNames(vmRootPath: URL) throws -> [String] {
        let excluded: Set<String> = [snapshotsDirectoryName, restoreStagingDirectoryName, restoreBackupDirectoryName, ".DS_Store"]
        let items = try FileManager.default.contentsOfDirectory(atPath: vmRootPath.path(percentEncoded: false))
        return items.filter { !excluded.contains($0) }
    }

    static func listSnapshots(vmRootPath: URL) -> [VMSnapshotModel] {
        let rootURL = snapshotsRootURL(vmRootPath: vmRootPath)
        guard let ids = try? FileManager.default.contentsOfDirectory(atPath: rootURL.path(percentEncoded: false)) else {
            return []
        }

        var snapshots: [VMSnapshotModel] = []
        for id in ids {
            let metaURL = snapshotMetaURL(vmRootPath: vmRootPath, snapshotId: id)
            guard let data = try? Data(contentsOf: metaURL) else {
                continue
            }
            guard let model = try? Self.jsonDecoder().decode(VMSnapshotModel.self, from: data) else {
                continue
            }
            snapshots.append(model)
        }
        return snapshots.sorted { $0.createdAt > $1.createdAt }
    }

    static func currentSnapshotID(vmRootPath: URL) -> String? {
        guard let currentID = readState(vmRootPath: vmRootPath).currentSnapshotID,
              listSnapshots(vmRootPath: vmRootPath).contains(where: { $0.id == currentID }) else {
            return nil
        }
        return currentID
    }

    static func selectedBackend(vmRootPath: URL) -> VMSnapshotBackend {
#if canImport(DiskImageKit)
        if #available(macOS 27.0, *),
           UserDefaults.standard.bool(forKey: EasyVMExperimentalFeatures.diskImageKitSnapshotsKey),
           configuredASIFBaseImageURLs(vmRootPath: vmRootPath) != nil {
            return .diskImageKitLayered
        }
#endif
        return .apfsClone
    }

    static func snapshotTree(vmRootPath: URL) -> [VMSnapshotTreeNode] {
        let snapshots = listSnapshots(vmRootPath: vmRootPath)
        let snapshotsByID = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.id, $0) })
        var childrenByParentID: [String: [VMSnapshotModel]] = [:]
        var roots: [VMSnapshotModel] = []

        for snapshot in snapshots {
            if let parentID = snapshot.parentSnapshotID,
               parentID != snapshot.id,
               snapshotsByID[parentID] != nil {
                childrenByParentID[parentID, default: []].append(snapshot)
            } else {
                roots.append(snapshot)
            }
        }

        func sorted(_ items: [VMSnapshotModel]) -> [VMSnapshotModel] {
            items.sorted { $0.createdAt < $1.createdAt }
        }

        var included = Set<String>()
        func makeNode(_ snapshot: VMSnapshotModel, ancestors: Set<String>) -> VMSnapshotTreeNode {
            included.insert(snapshot.id)
            let nextAncestors = ancestors.union([snapshot.id])
            let childNodes = sorted(childrenByParentID[snapshot.id] ?? [])
                .filter { !nextAncestors.contains($0.id) }
                .map { makeNode($0, ancestors: nextAncestors) }
            return VMSnapshotTreeNode(snapshot: snapshot, children: childNodes.isEmpty ? nil : childNodes)
        }

        var tree = sorted(roots).map { makeNode($0, ancestors: []) }
        // Corrupt cyclic metadata has no natural root. Keep those snapshots
        // visible as additional roots instead of silently losing them.
        for snapshot in sorted(snapshots) where !included.contains(snapshot.id) {
            tree.append(makeNode(snapshot, ancestors: []))
        }
        return tree
    }

    static func snapshotCount(vmRootPath: URL) -> Int {
        listSnapshots(vmRootPath: vmRootPath).count
    }

    static func createSnapshot(vmRootPath: URL, name: String) -> VMOSResult<VMSnapshotModel, String> {
#if canImport(DiskImageKit)
        if #available(macOS 27.0, *), selectedBackend(vmRootPath: vmRootPath) == .diskImageKitLayered {
            return createLayeredSnapshot(vmRootPath: vmRootPath, name: name)
        }
#endif
        return createAPFSCloneSnapshot(vmRootPath: vmRootPath, name: name)
    }

    private static func createAPFSCloneSnapshot(vmRootPath: URL, name: String) -> VMOSResult<VMSnapshotModel, String> {
        let snapshotId = UUID().uuidString
        let snapshotDir = snapshotDirURL(vmRootPath: vmRootPath, snapshotId: snapshotId)
        let filesDir = snapshotFilesURL(vmRootPath: vmRootPath, snapshotId: snapshotId)

        do {
            let fileNames = try listMachineFileNames(vmRootPath: vmRootPath)
            if fileNames.isEmpty {
                return .failure("No machine files found in \(vmRootPath.path(percentEncoded: false))")
            }

            try FileManager.default.createDirectory(at: filesDir, withIntermediateDirectories: true)

            for fileName in fileNames {
                let sourceURL = vmRootPath.appending(path: fileName)
                let targetURL = filesDir.appending(path: fileName)
                try FileManager.default.copyItem(at: sourceURL, to: targetURL)
            }

            let model = VMSnapshotModel(
                id: snapshotId,
                name: name,
                createdAt: Date(),
                parentSnapshotID: currentSnapshotID(vmRootPath: vmRootPath),
                totalSize: directoryAllocatedSize(filesDir),
                backend: .apfsClone
            )

            let data = try Self.jsonEncoder().encode(model)
            try data.write(to: snapshotMetaURL(vmRootPath: vmRootPath, snapshotId: model.id), options: .atomic)
            try writeCurrentSnapshotID(model.id, vmRootPath: vmRootPath)

            return .success(model)
        } catch {
            // remove the partial snapshot, keep the machine untouched
            try? FileManager.default.removeItem(at: snapshotDir)
            return .failure("Failed to create snapshot : \(error.localizedDescription)")
        }
    }

    static func restoreSnapshot(vmRootPath: URL, snapshot: VMSnapshotModel) -> VMOSResultVoid {
#if canImport(DiskImageKit)
        if #available(macOS 27.0, *), snapshot.backend == .diskImageKitLayered {
            return restoreLayeredSnapshot(vmRootPath: vmRootPath, snapshot: snapshot)
        }
#endif
        let fm = FileManager.default
        let filesDir = snapshotFilesURL(vmRootPath: vmRootPath, snapshotId: snapshot.id)

        guard let snapshotFileNames = try? fm.contentsOfDirectory(atPath: filesDir.path(percentEncoded: false)), !snapshotFileNames.isEmpty else {
            return .failure("Snapshot files are missing : \(filesDir.path(percentEncoded: false))")
        }

        let stagingDir = vmRootPath.appending(path: restoreStagingDirectoryName)
        let backupDir = vmRootPath.appending(path: restoreBackupDirectoryName)
        try? fm.removeItem(at: stagingDir)
        try? fm.removeItem(at: backupDir)

        // phase 1 : clone the snapshot into staging; the machine is untouched,
        // so a failure here is harmless
        do {
            try fm.createDirectory(at: stagingDir, withIntermediateDirectories: true)
            for fileName in snapshotFileNames {
                try fm.copyItem(at: filesDir.appending(path: fileName), to: stagingDir.appending(path: fileName))
            }
        } catch {
            try? fm.removeItem(at: stagingDir)
            return .failure("Failed to prepare snapshot files : \(error.localizedDescription)")
        }

        // phase 2 : swap with renames (fast on the same volume); every move is
        // tracked so a failure can be rolled back precisely
        var movedToBackup: [String] = []
        var movedFromStaging: [String] = []
        do {
            try fm.createDirectory(at: backupDir, withIntermediateDirectories: true)

            let currentFileNames = try listMachineFileNames(vmRootPath: vmRootPath)
            for fileName in currentFileNames {
                try fm.moveItem(at: vmRootPath.appending(path: fileName), to: backupDir.appending(path: fileName))
                movedToBackup.append(fileName)
            }

            for fileName in snapshotFileNames {
                try fm.moveItem(at: stagingDir.appending(path: fileName), to: vmRootPath.appending(path: fileName))
                movedFromStaging.append(fileName)
            }
        } catch {
            for fileName in movedFromStaging {
                try? fm.removeItem(at: vmRootPath.appending(path: fileName))
            }
            for fileName in movedToBackup {
                try? fm.moveItem(at: backupDir.appending(path: fileName), to: vmRootPath.appending(path: fileName))
            }
            try? fm.removeItem(at: stagingDir)
            try? fm.removeItem(at: backupDir)
            return .failure("Failed to restore snapshot, the machine was rolled back to its previous state : \(error.localizedDescription)")
        }

        do {
            try writeCurrentSnapshotID(snapshot.id, vmRootPath: vmRootPath)
        } catch {
            for fileName in movedFromStaging {
                try? fm.removeItem(at: vmRootPath.appending(path: fileName))
            }
            for fileName in movedToBackup {
                try? fm.moveItem(at: backupDir.appending(path: fileName), to: vmRootPath.appending(path: fileName))
            }
            try? fm.removeItem(at: stagingDir)
            try? fm.removeItem(at: backupDir)
            return .failure("Failed to record the restored snapshot branch, so the machine was rolled back : \(error.localizedDescription)")
        }
        try? fm.removeItem(at: stagingDir)
        try? fm.removeItem(at: backupDir)
        return .success
    }

    static func renameSnapshot(vmRootPath: URL, snapshot: VMSnapshotModel, newName: String) -> VMOSResultVoid {
        var model = snapshot
        model.name = newName
        do {
            let data = try Self.jsonEncoder().encode(model)
            try data.write(to: snapshotMetaURL(vmRootPath: vmRootPath, snapshotId: model.id))
            return .success
        } catch {
            return .failure("Failed to rename snapshot : \(error.localizedDescription)")
        }
    }

    static func deleteSnapshot(vmRootPath: URL, snapshot: VMSnapshotModel) -> VMOSResultVoid {
        if listSnapshots(vmRootPath: vmRootPath).contains(where: { $0.parentSnapshotID == snapshot.id }) {
            return .failure("Delete this snapshot's child snapshots first")
        }

        let snapshotDir = snapshotDirURL(vmRootPath: vmRootPath, snapshotId: snapshot.id)
        let deletingCurrentSnapshot = currentSnapshotID(vmRootPath: vmRootPath) == snapshot.id
        do {
            if deletingCurrentSnapshot {
                try writeCurrentSnapshotID(snapshot.parentSnapshotID, vmRootPath: vmRootPath)
            }
            do {
                try FileManager.default.removeItem(at: snapshotDir)
            } catch {
                if deletingCurrentSnapshot {
                    try? writeCurrentSnapshotID(snapshot.id, vmRootPath: vmRootPath)
                }
                throw error
            }
            pruneUnreferencedLayers(vmRootPath: vmRootPath)
            return .success
        } catch {
            return .failure("Failed to delete snapshot : \(error.localizedDescription)")
        }
    }

    private static func writeCurrentSnapshotID(_ snapshotID: String?, vmRootPath: URL) throws {
        var state = readState(vmRootPath: vmRootPath)
        state.currentSnapshotID = snapshotID
        try writeState(state, vmRootPath: vmRootPath)
    }

    private static func readState(vmRootPath: URL) -> VMSnapshotStoreState {
        guard let data = try? Data(contentsOf: stateURL(vmRootPath: vmRootPath)),
              let state = try? jsonDecoder().decode(VMSnapshotStoreState.self, from: data) else {
            return VMSnapshotStoreState()
        }
        return state
    }

    private static func writeState(_ state: VMSnapshotStoreState, vmRootPath: URL) throws {
        let rootURL = snapshotsRootURL(vmRootPath: vmRootPath)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let data = try jsonEncoder().encode(state)
        try data.write(to: stateURL(vmRootPath: vmRootPath), options: .atomic)
    }

    /// Returns nil unless every configured block device is ASIF. This avoids
    /// silently mixing layered and file-copy disk snapshots in one operation.
    private static func configuredASIFBaseImageURLs(vmRootPath: URL) -> [URL]? {
        let configURL = vmRootPath.appending(path: "config.json")
        guard let data = try? Data(contentsOf: configURL),
              let config = try? JSONDecoder().decode(VMSnapshotVMConfiguration.self, from: data) else {
            return nil
        }
        let disks = config.storageDevices.filter { $0.type == "Block" }
        guard !disks.isEmpty,
              disks.allSatisfy({ $0.format == "asif" || ($0.format == nil && $0.imagePath.lowercased().hasSuffix(".asif")) }) else {
            return nil
        }
        let urls = disks.map { vmRootPath.appending(path: $0.imagePath) }
        guard urls.allSatisfy({ FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) }) else {
            return nil
        }
        return urls.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

#if canImport(DiskImageKit)
    @available(macOS 27.0, *)
    private static func createLayeredSnapshot(vmRootPath: URL, name: String) -> VMOSResult<VMSnapshotModel, String> {
        let snapshotID = UUID().uuidString
        let snapshotDir = snapshotDirURL(vmRootPath: vmRootPath, snapshotId: snapshotID)
        let filesDir = snapshotFilesURL(vmRootPath: vmRootPath, snapshotId: snapshotID)
        guard let bases = configuredASIFBaseImageURLs(vmRootPath: vmRootPath) else {
            return .failure("DiskImageKit snapshots require every configured block disk to use ASIF.")
        }

        var state = readState(vmRootPath: vmRootPath)
        let frozenLayers = bases.map { base in
            VMSnapshotDiskLayer(
                baseImageName: base.lastPathComponent,
                layerPaths: state.activeDiskLayers[base.lastPathComponent] ?? []
            )
        }
        var createdLayerURLs: [URL] = []

        do {
            try FileManager.default.createDirectory(at: filesDir, withIntermediateDirectories: true)
            for fileName in try listMachineFileNames(vmRootPath: vmRootPath)
            where !fileName.lowercased().hasSuffix(".asif") {
                try FileManager.default.copyItem(
                    at: vmRootPath.appending(path: fileName),
                    to: filesDir.appending(path: fileName)
                )
            }

            for base in bases {
                let existing = state.activeDiskLayers[base.lastPathComponent] ?? []
                let newLayerURL = try appendNewOverlay(baseURL: base, relativeLayerPaths: existing, vmRootPath: vmRootPath)
                createdLayerURLs.append(newLayerURL)
                state.activeDiskLayers[base.lastPathComponent] = existing + [relativePath(newLayerURL, under: vmRootPath)]
            }

            let model = VMSnapshotModel(
                id: snapshotID,
                name: name,
                createdAt: Date(),
                parentSnapshotID: state.currentSnapshotID,
                totalSize: directoryAllocatedSize(snapshotDir) + frozenLayers.reduce(0) { total, disk in
                    guard let lastPath = disk.layerPaths.last else { return total }
                    return total + fileAllocatedSize(vmRootPath.appending(path: lastPath))
                },
                backend: .diskImageKitLayered,
                diskLayers: frozenLayers
            )
            try jsonEncoder().encode(model).write(to: snapshotMetaURL(vmRootPath: vmRootPath, snapshotId: snapshotID), options: .atomic)
            state.currentSnapshotID = snapshotID
            try writeState(state, vmRootPath: vmRootPath)
            return .success(model)
        } catch {
            for url in createdLayerURLs { try? FileManager.default.removeItem(at: url) }
            try? FileManager.default.removeItem(at: snapshotDir)
            return .failure("Failed to create the DiskImageKit snapshot: \(error.localizedDescription)")
        }
    }

    @available(macOS 27.0, *)
    private static func restoreLayeredSnapshot(vmRootPath: URL, snapshot: VMSnapshotModel) -> VMOSResultVoid {
        var state = readState(vmRootPath: vmRootPath)
        var createdLayerURLs: [URL] = []
        let fm = FileManager.default
        let filesDir = snapshotFilesURL(vmRootPath: vmRootPath, snapshotId: snapshot.id)
        let stagingDir = vmRootPath.appending(path: restoreStagingDirectoryName)
        let backupDir = vmRootPath.appending(path: restoreBackupDirectoryName)
        var movedToBackup: [String] = []
        var movedFromStaging: [String] = []
        do {
            for disk in snapshot.diskLayers {
                let baseURL = vmRootPath.appending(path: disk.baseImageName)
                guard FileManager.default.fileExists(atPath: baseURL.path(percentEncoded: false)) else {
                    throw VMSnapshotError.message("The ASIF base image \(disk.baseImageName) is missing.")
                }
                let layerURL = try appendNewOverlay(baseURL: baseURL, relativeLayerPaths: disk.layerPaths, vmRootPath: vmRootPath)
                createdLayerURLs.append(layerURL)
                state.activeDiskLayers[disk.baseImageName] = disk.layerPaths + [relativePath(layerURL, under: vmRootPath)]
            }

            try? fm.removeItem(at: stagingDir)
            try? fm.removeItem(at: backupDir)
            try fm.createDirectory(at: stagingDir, withIntermediateDirectories: true)
            let snapshotFileNames = try fm.contentsOfDirectory(atPath: filesDir.path(percentEncoded: false))
            for fileName in snapshotFileNames {
                try fm.copyItem(at: filesDir.appending(path: fileName), to: stagingDir.appending(path: fileName))
            }

            try fm.createDirectory(at: backupDir, withIntermediateDirectories: true)
            let currentNonDiskFiles = try listMachineFileNames(vmRootPath: vmRootPath)
                .filter { !$0.lowercased().hasSuffix(".asif") }
            for fileName in currentNonDiskFiles {
                try fm.moveItem(at: vmRootPath.appending(path: fileName), to: backupDir.appending(path: fileName))
                movedToBackup.append(fileName)
            }
            for fileName in snapshotFileNames {
                try fm.moveItem(at: stagingDir.appending(path: fileName), to: vmRootPath.appending(path: fileName))
                movedFromStaging.append(fileName)
            }

            state.currentSnapshotID = snapshot.id
            try writeState(state, vmRootPath: vmRootPath)
            pruneUnreferencedLayers(vmRootPath: vmRootPath)
            try? fm.removeItem(at: stagingDir)
            try? fm.removeItem(at: backupDir)
            return .success
        } catch {
            for fileName in movedFromStaging {
                try? fm.removeItem(at: vmRootPath.appending(path: fileName))
            }
            for fileName in movedToBackup {
                try? fm.moveItem(at: backupDir.appending(path: fileName), to: vmRootPath.appending(path: fileName))
            }
            try? fm.removeItem(at: stagingDir)
            try? fm.removeItem(at: backupDir)
            for url in createdLayerURLs { try? FileManager.default.removeItem(at: url) }
            return .failure("Failed to restore the DiskImageKit snapshot: \(error.localizedDescription)")
        }
    }

    @available(macOS 27.0, *)
    static func layeredDiskImage(baseURL: URL, vmRootPath: URL) throws -> DiskImage? {
        guard selectedBackend(vmRootPath: vmRootPath) == .diskImageKitLayered else { return nil }
        var state = readState(vmRootPath: vmRootPath)
        var paths = state.activeDiskLayers[baseURL.lastPathComponent] ?? []
        if paths.isEmpty {
            let layerURL = try appendNewOverlay(baseURL: baseURL, relativeLayerPaths: [], vmRootPath: vmRootPath)
            paths = [relativePath(layerURL, under: vmRootPath)]
            state.activeDiskLayers[baseURL.lastPathComponent] = paths
            try writeState(state, vmRootPath: vmRootPath)
        }
        return try openStack(baseURL: baseURL, relativeLayerPaths: paths, vmRootPath: vmRootPath)
    }

    @available(macOS 27.0, *)
    private static func appendNewOverlay(baseURL: URL, relativeLayerPaths: [String], vmRootPath: URL) throws -> URL {
        let layersRoot = snapshotsRootURL(vmRootPath: vmRootPath).appending(path: "Layers")
        try FileManager.default.createDirectory(at: layersRoot, withIntermediateDirectories: true)
        let newLayerURL = layersRoot.appending(path: "\(UUID().uuidString).asif")
        let image = try openStack(baseURL: baseURL, relativeLayerPaths: relativeLayerPaths, vmRootPath: vmRootPath)
        _ = try image.appending(.asifLayer(url: newLayerURL, type: .overlay))
        return newLayerURL
    }

    @available(macOS 27.0, *)
    private static func openStack(baseURL: URL, relativeLayerPaths: [String], vmRootPath: URL) throws -> DiskImage {
        var image = try DiskImage(opening: .open(url: baseURL, mode: .readOnly))
        for (index, path) in relativeLayerPaths.enumerated() {
            let mode: OpenConfiguration.Mode = index == relativeLayerPaths.index(before: relativeLayerPaths.endIndex) ? .readWrite : .readOnly
            let layer = try DiskImage(opening: .open(url: vmRootPath.appending(path: path), mode: mode))
            image = try image.appending(layer)
        }
        return image
    }

    private static func relativePath(_ url: URL, under root: URL) -> String {
        url.standardizedFileURL.pathComponents
            .dropFirst(root.standardizedFileURL.pathComponents.count)
            .joined(separator: "/")
    }
#endif

    private static func pruneUnreferencedLayers(vmRootPath: URL) {
        let layersRoot = snapshotsRootURL(vmRootPath: vmRootPath).appending(path: "Layers")
        guard let layerNames = try? FileManager.default.contentsOfDirectory(atPath: layersRoot.path(percentEncoded: false)) else {
            return
        }
        var referenced = Set(readState(vmRootPath: vmRootPath).activeDiskLayers.values.flatMap { $0 })
        for snapshot in listSnapshots(vmRootPath: vmRootPath) {
            referenced.formUnion(snapshot.diskLayers.flatMap(\.layerPaths))
        }
        for layerName in layerNames {
            let url = layersRoot.appending(path: layerName)
            let path = relativePathForPruning(url, under: vmRootPath)
            if !referenced.contains(path) {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    private static func relativePathForPruning(_ url: URL, under root: URL) -> String {
        url.standardizedFileURL.pathComponents
            .dropFirst(root.standardizedFileURL.pathComponents.count)
            .joined(separator: "/")
    }

    // size on disk of every regular file below url
    private static func directoryAllocatedSize(_ url: URL) -> UInt64 {
        var total: UInt64 = 0
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys)) else {
            return 0
        }
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: keys) else {
                continue
            }
            if values.isRegularFile == true {
                total += UInt64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
            }
        }
        return total
    }

    private static func fileAllocatedSize(_ url: URL) -> UInt64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileSizeKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return 0 }
        return UInt64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
    }

    private static func jsonEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func jsonDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

private enum VMSnapshotError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let message): message
        }
    }
}
