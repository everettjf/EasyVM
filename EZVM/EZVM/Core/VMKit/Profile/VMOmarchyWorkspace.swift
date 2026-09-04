import Foundation
import Virtualization

public struct VMOmarchyWorkspaceMetadata: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 2

    public let schemaVersion: Int
    public let productID: String
    public let createdAt: Date
    public let factoryImageVersion: String?
    public let omarchyRevision: String?
    public let guestAgentVersion: String?
    public let guestCapabilities: [String]?

    public init(
        schemaVersion: Int = currentSchemaVersion,
        productID: String,
        createdAt: Date,
        factoryImageVersion: String? = nil,
        omarchyRevision: String? = nil,
        guestAgentVersion: String? = nil,
        guestCapabilities: [String]? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.productID = productID
        self.createdAt = createdAt
        self.factoryImageVersion = factoryImageVersion
        self.omarchyRevision = omarchyRevision
        self.guestAgentVersion = guestAgentVersion
        self.guestCapabilities = guestCapabilities
    }
}

public struct VMOmarchyWorkspaceLayout: Equatable {
    public let applicationSupportRoot: URL

    public init(applicationSupportRoot: URL) {
        self.applicationSupportRoot = applicationSupportRoot.standardizedFileURL
    }

    public static func userDomain(fileManager: FileManager = .default) throws -> Self {
        guard let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw VMOmarchyWorkspaceError.applicationSupportUnavailable
        }
        return Self(applicationSupportRoot: support.appending(path: "EZVM Omarchy", directoryHint: .isDirectory))
    }

    public var workspace: URL { applicationSupportRoot.appending(path: "Workspace", directoryHint: .isDirectory) }
    public var disk: URL { workspace.appending(path: "Disk.asif") }
    public var configuration: URL { workspace.appending(path: "Configuration.json") }
    public var machineIdentifier: URL { workspace.appending(path: "MachineIdentifier") }
    public var boot: URL { workspace.appending(path: "Boot", directoryHint: .isDirectory) }
    public var efiVariableStore: URL { boot.appending(path: "EFIVariableStore") }
    public var snapshots: URL { workspace.appending(path: "Snapshots", directoryHint: .isDirectory) }
    public var enrollment: URL { applicationSupportRoot.appending(path: "Enrollment", directoryHint: .isDirectory) }
    public var shared: URL { applicationSupportRoot.appending(path: "Shared", directoryHint: .isDirectory) }
    public var cache: URL { applicationSupportRoot.appending(path: "Cache", directoryHint: .isDirectory) }
    public var diagnostics: URL { applicationSupportRoot.appending(path: "Diagnostics", directoryHint: .isDirectory) }
    public var recovery: URL { applicationSupportRoot.appending(path: "Recovery", directoryHint: .isDirectory) }
}

/// Restricts destructive acceptance operations to macOS temporary storage.
/// Both `/tmp` and `/private/tmp` must remain explicit because URL
/// standardization can preserve one spelling for a child while canonicalizing
/// the directory itself to the other spelling.
public enum VMOmarchyTemporaryPathPolicy {
    public static func contains(
        _ candidate: URL,
        fileManager: FileManager = .default
    ) -> Bool {
        guard let path = resolvedPath(
            forPotentiallyMissing: candidate,
            fileManager: fileManager
        ) else { return false }
        let allowedRootPaths = Set([
            fileManager.temporaryDirectory.standardizedFileURL.resolvingSymlinksInPath().path,
            "/tmp",
            "/private/tmp",
        ])
        return allowedRootPaths.contains { root in
            path == root || path.hasPrefix(root + "/")
        }
    }

    private static func resolvedPath(
        forPotentiallyMissing candidate: URL,
        fileManager: FileManager
    ) -> String? {
        var cursor = candidate.standardizedFileURL
        var missingComponents: [String] = []

        while cursor.path != "/" {
            let isSymbolicLink = (try? fileManager.destinationOfSymbolicLink(
                atPath: cursor.path
            )) != nil
            if fileManager.fileExists(atPath: cursor.path) {
                let resolved = cursor.resolvingSymlinksInPath()
                return missingComponents.reduce(resolved) { partial, component in
                    partial.appending(path: component)
                }.standardizedFileURL.path
            }
            // A dangling link could later be redirected outside temporary
            // storage, so it is never a valid acceptance root.
            if isSymbolicLink { return nil }
            missingComponents.insert(cursor.lastPathComponent, at: 0)
            cursor.deleteLastPathComponent()
        }

        return nil
    }
}

public enum VMOmarchyWorkspaceState: Equatable {
    case notPrepared
    case migrationRequired(fromVersion: Int)
    case ready
    case recovering(reason: String)
}

public enum VMOmarchyWorkspaceError: Error, Equatable {
    case applicationSupportUnavailable
    case workspaceAlreadyExists
    case invalidFactoryDisk
    case unsafeWorkspacePath
    case publicationFailed(String)
    case enrollmentFailed(String)
    case workspaceNotRecoverable
    case recoveryFailed(String)
    case invalidWorkspaceMetadata
    case migrationFailed(String)
    case metadataUpdateFailed(String)
}

extension VMOmarchyWorkspaceError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .applicationSupportUnavailable:
            "The Application Support folder is unavailable."
        case .workspaceAlreadyExists:
            "An Omarchy workspace already exists."
        case .invalidFactoryDisk:
            "The verified Omarchy factory disk is missing or invalid."
        case .unsafeWorkspacePath:
            "The Omarchy data folder contains an unsafe symbolic link."
        case .publicationFailed(let reason):
            "The Omarchy workspace could not be created: \(reason)"
        case .enrollmentFailed(let reason):
            "The Omarchy integration identity could not be created: \(reason)"
        case .workspaceNotRecoverable:
            "Only a broken Omarchy workspace can be preserved for recovery."
        case .recoveryFailed(let reason):
            "The broken Omarchy workspace could not be preserved: \(reason)"
        case .invalidWorkspaceMetadata:
            "The Omarchy workspace metadata is invalid or unsupported."
        case .migrationFailed(let reason):
            "The Omarchy workspace could not be migrated: \(reason)"
        case .metadataUpdateFailed(let reason):
            "The Omarchy integration metadata could not be recorded: \(reason)"
        }
    }
}

public struct VMOmarchyWorkspaceManager {
    public let layout: VMOmarchyWorkspaceLayout
    private let fileManager: FileManager

    public init(layout: VMOmarchyWorkspaceLayout, fileManager: FileManager = .default) {
        self.layout = layout
        self.fileManager = fileManager
    }

    public func inspect() -> VMOmarchyWorkspaceState {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: layout.workspace.path, isDirectory: &isDirectory) else {
            return .notPrepared
        }
        guard isDirectory.boolValue,
              !isSymbolicLink(layout.workspace),
              requiredFiles.allSatisfy({ regularFileExists($0) }) else {
            return .recovering(reason: "The Omarchy workspace is incomplete or unsafe.")
        }
        guard let metadata = decodedMetadata(),
              metadata.productID == VMOmarchyProfile.production.productID,
              metadata.schemaVersion > 0,
              metadata.schemaVersion <= VMOmarchyWorkspaceMetadata.currentSchemaVersion else {
            return .recovering(reason: "The Omarchy workspace metadata is invalid or unsupported.")
        }
        guard let identifierData = try? Data(contentsOf: layout.machineIdentifier),
              VZGenericMachineIdentifier(dataRepresentation: identifierData) != nil else {
            return .recovering(reason: "The Omarchy machine identity is invalid.")
        }
        if metadata.schemaVersion < VMOmarchyWorkspaceMetadata.currentSchemaVersion {
            return .migrationRequired(fromVersion: metadata.schemaVersion)
        }
        return .ready
    }

    public func metadata() throws -> VMOmarchyWorkspaceMetadata {
        guard let metadata = decodedMetadata(),
              metadata.schemaVersion == VMOmarchyWorkspaceMetadata.currentSchemaVersion,
              metadata.productID == VMOmarchyProfile.production.productID else {
            throw VMOmarchyWorkspaceError.invalidWorkspaceMetadata
        }
        return metadata
    }

    public func migrateWorkspace(availableCapacityBytes: Int64? = nil) throws {
        try migrateWorkspace(availableCapacityBytes: availableCapacityBytes) { data, destination in
            try data.write(to: destination, options: .atomic)
        }
    }

    public func recordGuestIntegration(
        omarchyRevision: String?,
        agentVersion: String,
        capabilities: Set<String>
    ) throws {
        guard !agentVersion.isEmpty, agentVersion.utf8.count <= 128,
              (omarchyRevision?.utf8.count ?? 0) <= 256,
              capabilities.count <= 64,
              capabilities.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 128 }) else {
            throw VMOmarchyWorkspaceError.metadataUpdateFailed("The Guest Agent returned invalid version metadata.")
        }
        guard inspect() == .ready else {
            throw VMOmarchyWorkspaceError.invalidWorkspaceMetadata
        }
        let old = try metadata()
        let revision = omarchyRevision.flatMap { $0.isEmpty ? nil : $0 } ?? old.omarchyRevision
        let sortedCapabilities = capabilities.sorted()
        guard old.omarchyRevision != revision
                || old.guestAgentVersion != agentVersion
                || old.guestCapabilities != sortedCapabilities else { return }
        let updated = VMOmarchyWorkspaceMetadata(
            productID: old.productID,
            createdAt: old.createdAt,
            factoryImageVersion: old.factoryImageVersion,
            omarchyRevision: revision,
            guestAgentVersion: agentVersion,
            guestCapabilities: sortedCapabilities
        )
        do {
            try JSONEncoder().encode(updated).write(to: layout.configuration, options: .atomic)
        } catch {
            throw VMOmarchyWorkspaceError.metadataUpdateFailed(error.localizedDescription)
        }
    }

    func migrateWorkspace(
        availableCapacityBytes: Int64? = nil,
        metadataWriter: (Data, URL) throws -> Void
    ) throws {
        guard case .migrationRequired(let fromVersion) = inspect(),
              fromVersion == 1,
              let old = decodedMetadata() else {
            throw VMOmarchyWorkspaceError.invalidWorkspaceMetadata
        }
        switch VMSnapshotManager.createSnapshot(
            vmRootPath: layout.workspace,
            name: "Before workspace migration 1 to 2",
            isProtected: true,
            availableCapacityBytes: availableCapacityBytes
        ) {
        case .failure(let reason):
            throw VMOmarchyWorkspaceError.migrationFailed(reason)
        case .success:
            break
        }
        let migrated = VMOmarchyWorkspaceMetadata(
            productID: old.productID,
            createdAt: old.createdAt,
            factoryImageVersion: old.factoryImageVersion,
            omarchyRevision: old.omarchyRevision,
            guestAgentVersion: old.guestAgentVersion,
            guestCapabilities: old.guestCapabilities
        )
        do {
            try metadataWriter(try JSONEncoder().encode(migrated), layout.configuration)
        } catch {
            throw VMOmarchyWorkspaceError.migrationFailed(error.localizedDescription)
        }
        guard inspect() == .ready else {
            throw VMOmarchyWorkspaceError.migrationFailed("The migrated workspace did not pass validation.")
        }
    }

    /// Moves an invalid workspace out of the live location without deleting
    /// user data. A subsequent onboarding run can then create a clean workspace.
    @discardableResult
    public func quarantineBrokenWorkspace(now: Date = Date()) throws -> URL {
        guard case .recovering = inspect(),
              fileManager.fileExists(atPath: layout.workspace.path),
              !isSymbolicLink(layout.workspace) else {
            throw VMOmarchyWorkspaceError.workspaceNotRecoverable
        }
        try fileManager.createDirectory(at: layout.recovery, withIntermediateDirectories: true)
        guard !isSymbolicLink(layout.recovery) else {
            throw VMOmarchyWorkspaceError.unsafeWorkspacePath
        }
        if fileManager.fileExists(atPath: layout.enrollment.path) {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: layout.enrollment.path, isDirectory: &isDirectory),
                  isDirectory.boolValue,
                  !isSymbolicLink(layout.enrollment) else {
                throw VMOmarchyWorkspaceError.unsafeWorkspacePath
            }
        }

        let destination = uniqueRecoveryDestination(now: now)
        let staging = layout.recovery.appending(
            path: ".preserving.\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let stagedWorkspace = staging.appending(path: "Workspace", directoryHint: .isDirectory)
        let stagedEnrollment = staging.appending(path: "Enrollment", directoryHint: .isDirectory)
        var workspaceMoved = false
        var enrollmentMoved = false
        do {
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: false)
            try fileManager.moveItem(at: layout.workspace, to: stagedWorkspace)
            workspaceMoved = true
            if fileManager.fileExists(atPath: layout.enrollment.path) {
                try fileManager.moveItem(at: layout.enrollment, to: stagedEnrollment)
                enrollmentMoved = true
            }
            try fileManager.moveItem(at: staging, to: destination)
            return destination
        } catch {
            if enrollmentMoved,
               !fileManager.fileExists(atPath: layout.enrollment.path),
               fileManager.fileExists(atPath: stagedEnrollment.path) {
                try? fileManager.moveItem(at: stagedEnrollment, to: layout.enrollment)
            }
            if workspaceMoved,
               !fileManager.fileExists(atPath: layout.workspace.path),
               fileManager.fileExists(atPath: stagedWorkspace.path) {
                try? fileManager.moveItem(at: stagedWorkspace, to: layout.workspace)
            }
            try? fileManager.removeItem(at: staging)
            throw VMOmarchyWorkspaceError.recoveryFailed(error.localizedDescription)
        }
    }

    public func prepare(
        factoryDisk: URL,
        configuration: Data,
        machineIdentifier: Data
    ) throws {
        guard inspect() == .notPrepared else { throw VMOmarchyWorkspaceError.workspaceAlreadyExists }
        guard regularFileExists(factoryDisk), factoryDisk.pathExtension.lowercased() == "asif" else {
            throw VMOmarchyWorkspaceError.invalidFactoryDisk
        }
        try fileManager.createDirectory(at: layout.applicationSupportRoot, withIntermediateDirectories: true)
        guard !isSymbolicLink(layout.applicationSupportRoot) else {
            throw VMOmarchyWorkspaceError.unsafeWorkspacePath
        }

        let staging = layout.applicationSupportRoot.appending(
            path: ".Workspace.preparing.\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        do {
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: false)
            try fileManager.copyItem(at: factoryDisk, to: staging.appending(path: "Disk.asif"))
            try configuration.write(to: staging.appending(path: "Configuration.json"), options: [.atomic])
            try machineIdentifier.write(to: staging.appending(path: "MachineIdentifier"), options: [.atomic])
            try fileManager.createDirectory(
                at: staging.appending(path: "Snapshots", directoryHint: .isDirectory),
                withIntermediateDirectories: false
            )
            try fileManager.createDirectory(
                at: staging.appending(path: "Boot", directoryHint: .isDirectory),
                withIntermediateDirectories: false
            )
            try createSupportDirectories()
            switch VMGuestAgentEnrollmentStore.loadOrCreate(
                machineIdentifierData: machineIdentifier,
                directoryURL: layout.enrollment
            ) {
            case .success: break
            case .failure(let error): throw VMOmarchyWorkspaceError.enrollmentFailed(error)
            }
            // Publishing the fully populated directory is the final operation,
            // so observers can only see no workspace or a complete workspace.
            try fileManager.moveItem(at: staging, to: layout.workspace)
        } catch let error as VMOmarchyWorkspaceError {
            try? fileManager.removeItem(at: staging)
            throw error
        } catch {
            try? fileManager.removeItem(at: staging)
            throw VMOmarchyWorkspaceError.publicationFailed(error.localizedDescription)
        }
    }

    private var requiredFiles: [URL] {
        [layout.disk, layout.configuration, layout.machineIdentifier]
    }

    private func decodedMetadata() -> VMOmarchyWorkspaceMetadata? {
        guard regularFileExists(layout.configuration) else { return nil }
        return try? JSONDecoder().decode(
            VMOmarchyWorkspaceMetadata.self,
            from: Data(contentsOf: layout.configuration)
        )
    }

    private func uniqueRecoveryDestination(now: Date) -> URL {
        let timestamp = ISO8601DateFormatter().string(from: now)
            .replacingOccurrences(of: ":", with: "-")
        var destination = layout.recovery.appending(
            path: "Recovery-\(timestamp)",
            directoryHint: .isDirectory
        )
        var suffix = 1
        while fileManager.fileExists(atPath: destination.path) {
            destination = layout.recovery.appending(
                path: "Recovery-\(timestamp)-\(suffix)",
                directoryHint: .isDirectory
            )
            suffix += 1
        }
        return destination
    }

    private func createSupportDirectories() throws {
        for directory in [layout.enrollment, layout.shared, layout.cache, layout.diagnostics, layout.recovery] {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    private func regularFileExists(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && !isDirectory.boolValue
            && !isSymbolicLink(url)
    }

    private func isSymbolicLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }
}

public struct VMOmarchyRecoveryPoint: Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let createdAt: Date
    public let allocatedSize: UInt64?
    public let isProtected: Bool

    public init(id: String, name: String, createdAt: Date, allocatedSize: UInt64?, isProtected: Bool) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.allocatedSize = allocatedSize
        self.isProtected = isProtected
    }
}

public enum VMOmarchyRecoveryError: Error, Equatable, LocalizedError {
    case workspaceNotReady
    case operationFailed(String)
    case recoveryPointNotFound
    case restoredWorkspaceInvalid(String)

    public var errorDescription: String? {
        switch self {
        case .workspaceNotReady:
            "Omarchy must be installed and stopped before changing recovery points."
        case .operationFailed(let reason):
            "The Omarchy recovery operation failed: \(reason)"
        case .recoveryPointNotFound:
            "That Omarchy recovery point no longer exists."
        case .restoredWorkspaceInvalid(let reason):
            "The recovery point was restored, but the workspace is invalid: \(reason)"
        }
    }
}

/// A narrow Omarchy-facing seam over EZVM's shared transactional snapshot
/// implementation. Callers must keep the virtual machine stopped while an
/// operation is in progress.
public struct VMOmarchyRecoveryManager {
    public let workspaceManager: VMOmarchyWorkspaceManager

    public init(workspaceManager: VMOmarchyWorkspaceManager) {
        self.workspaceManager = workspaceManager
    }

    public func recoveryPoints() -> [VMOmarchyRecoveryPoint] {
        VMSnapshotManager.listSnapshots(vmRootPath: workspaceManager.layout.workspace).map(Self.point)
    }

    @discardableResult
    public func createProtectedPreUpdatePoint(
        targetVersion: String,
        availableCapacityBytes: Int64? = nil
    ) throws -> VMOmarchyRecoveryPoint {
        let version = targetVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !version.isEmpty else {
            throw VMOmarchyRecoveryError.operationFailed("The target version is empty.")
        }
        return try createProtectedPoint(
            name: "Before update to \(version)",
            availableCapacityBytes: availableCapacityBytes
        )
    }

    @discardableResult
    public func createProtectedBackup(
        name: String = "Protected backup",
        availableCapacityBytes: Int64? = nil
    ) throws -> VMOmarchyRecoveryPoint {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty else {
            throw VMOmarchyRecoveryError.operationFailed("The recovery point name is empty.")
        }
        return try createProtectedPoint(name: normalizedName, availableCapacityBytes: availableCapacityBytes)
    }

    private func createProtectedPoint(
        name: String,
        availableCapacityBytes: Int64?
    ) throws -> VMOmarchyRecoveryPoint {
        try ensureRecoveredWorkspaceIsReady()
        switch VMSnapshotManager.createSnapshot(
            vmRootPath: workspaceManager.layout.workspace,
            name: name,
            isProtected: true,
            availableCapacityBytes: availableCapacityBytes
        ) {
        case .success(let snapshot):
            guard let committed = VMSnapshotManager.listSnapshots(vmRootPath: workspaceManager.layout.workspace)
                .first(where: { $0.id == snapshot.id }) else {
                throw VMOmarchyRecoveryError.operationFailed(
                    "The recovery point was created but its committed metadata could not be read."
                )
            }
            return Self.point(committed)
        case .failure(let reason): throw VMOmarchyRecoveryError.operationFailed(reason)
        }
    }

    public func recoverInterruptedOperations() throws {
        var isDirectory: ObjCBool = false
        let workspace = workspaceManager.layout.workspace
        guard FileManager.default.fileExists(atPath: workspace.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              (try? workspace.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else {
            throw VMOmarchyRecoveryError.workspaceNotReady
        }
        switch VMSnapshotManager.recoverInterruptedRestore(vmRootPath: workspaceManager.layout.workspace) {
        case .success: return
        case .failure(let reason): throw VMOmarchyRecoveryError.operationFailed(reason)
        }
    }

    public func restore(id: String, availableCapacityBytes: Int64? = nil) throws {
        try ensureRecoveredWorkspaceIsReady()
        guard let snapshot = VMSnapshotManager.listSnapshots(vmRootPath: workspaceManager.layout.workspace)
            .first(where: { $0.id == id }) else {
            throw VMOmarchyRecoveryError.recoveryPointNotFound
        }
        switch VMSnapshotManager.restoreSnapshot(
            vmRootPath: workspaceManager.layout.workspace,
            snapshot: snapshot,
            availableCapacityBytes: availableCapacityBytes
        ) {
        case .success: break
        case .failure(let reason): throw VMOmarchyRecoveryError.operationFailed(reason)
        }
        if case .recovering(let reason) = workspaceManager.inspect() {
            throw VMOmarchyRecoveryError.restoredWorkspaceInvalid(reason)
        }
    }

    private static func point(_ snapshot: VMSnapshotModel) -> VMOmarchyRecoveryPoint {
        VMOmarchyRecoveryPoint(
            id: snapshot.id,
            name: snapshot.name,
            createdAt: snapshot.createdAt,
            allocatedSize: snapshot.totalSize,
            isProtected: snapshot.isProtected
        )
    }

    private func ensureRecoveredWorkspaceIsReady() throws {
        try recoverInterruptedOperations()
        guard workspaceManager.inspect() == .ready else {
            throw VMOmarchyRecoveryError.workspaceNotReady
        }
    }
}
