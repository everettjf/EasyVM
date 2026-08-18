//
//  VMSnapshotManager.swift
//  EasyVM
//
//  Created by everettjf on 2026/8/18.
//

import Foundation

#if arch(arm64)

/*
 File level snapshots for a virtual machine bundle.

 A snapshot is a copy of every file in the bundle (disk image, auxiliary
 storage, NVRAM, machine identifier, config ...) stored under
 <bundle>/Snapshots/<id>/files, plus a snapshot.json describing it.

 Copies are made with FileManager.copyItem, which clones files on APFS
 (copy-on-write), so taking a snapshot is fast and only consumes space as
 the disk image diverges afterwards.

 Snapshots must be taken/restored while the virtual machine is shut down.
 */
struct VMSnapshotModel: Identifiable, Codable {
    let id: String
    let name: String
    let createdAt: Date

    var displayDate: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: createdAt)
    }
}


class VMSnapshotManager {

    static let snapshotsDirectoryName = "Snapshots"
    private static let filesDirectoryName = "files"
    private static let metaFileName = "snapshot.json"

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

    // machine files are everything in the bundle except the Snapshots directory itself
    private static func listMachineFileNames(vmRootPath: URL) throws -> [String] {
        let items = try FileManager.default.contentsOfDirectory(atPath: vmRootPath.path(percentEncoded: false))
        return items.filter { $0 != snapshotsDirectoryName && $0 != ".DS_Store" }
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

    static func createSnapshot(vmRootPath: URL, name: String) -> VMOSResult<VMSnapshotModel, String> {
        let model = VMSnapshotModel(id: UUID().uuidString, name: name, createdAt: Date())

        let snapshotDir = snapshotDirURL(vmRootPath: vmRootPath, snapshotId: model.id)
        let filesDir = snapshotFilesURL(vmRootPath: vmRootPath, snapshotId: model.id)

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

            let data = try Self.jsonEncoder().encode(model)
            try data.write(to: snapshotMetaURL(vmRootPath: vmRootPath, snapshotId: model.id))

            return .success(model)
        } catch {
            // remove the partial snapshot, keep the machine untouched
            try? FileManager.default.removeItem(at: snapshotDir)
            return .failure("Failed to create snapshot : \(error.localizedDescription)")
        }
    }

    static func restoreSnapshot(vmRootPath: URL, snapshot: VMSnapshotModel) -> VMOSResultVoid {
        let filesDir = snapshotFilesURL(vmRootPath: vmRootPath, snapshotId: snapshot.id)

        guard let snapshotFileNames = try? FileManager.default.contentsOfDirectory(atPath: filesDir.path(percentEncoded: false)), !snapshotFileNames.isEmpty else {
            return .failure("Snapshot files are missing : \(filesDir.path(percentEncoded: false))")
        }

        do {
            // remove current machine files, then clone the snapshot files back
            let currentFileNames = try listMachineFileNames(vmRootPath: vmRootPath)
            for fileName in currentFileNames {
                try FileManager.default.removeItem(at: vmRootPath.appending(path: fileName))
            }

            for fileName in snapshotFileNames {
                let sourceURL = filesDir.appending(path: fileName)
                let targetURL = vmRootPath.appending(path: fileName)
                try FileManager.default.copyItem(at: sourceURL, to: targetURL)
            }
            return .success
        } catch {
            return .failure("Failed to restore snapshot : \(error.localizedDescription)")
        }
    }

    static func deleteSnapshot(vmRootPath: URL, snapshot: VMSnapshotModel) -> VMOSResultVoid {
        let snapshotDir = snapshotDirURL(vmRootPath: vmRootPath, snapshotId: snapshot.id)
        do {
            try FileManager.default.removeItem(at: snapshotDir)
            return .success
        } catch {
            return .failure("Failed to delete snapshot : \(error.localizedDescription)")
        }
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

#endif
