import Foundation
import Virtualization

public struct VMOmarchyWorkspaceMetadata: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let productID: String
    public let createdAt: Date
    public let factoryImageVersion: String?

    public init(
        schemaVersion: Int = currentSchemaVersion,
        productID: String,
        createdAt: Date,
        factoryImageVersion: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.productID = productID
        self.createdAt = createdAt
        self.factoryImageVersion = factoryImageVersion
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

public enum VMOmarchyWorkspaceState: Equatable {
    case notPrepared
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
        guard let metadata = try? JSONDecoder().decode(
            VMOmarchyWorkspaceMetadata.self,
            from: Data(contentsOf: layout.configuration)
        ), metadata.schemaVersion == VMOmarchyWorkspaceMetadata.currentSchemaVersion,
           metadata.productID == VMOmarchyProfile.production.productID else {
            return .recovering(reason: "The Omarchy workspace metadata is invalid or unsupported.")
        }
        guard let identifierData = try? Data(contentsOf: layout.machineIdentifier),
              VZGenericMachineIdentifier(dataRepresentation: identifierData) != nil else {
            return .recovering(reason: "The Omarchy machine identity is invalid.")
        }
        return .ready
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
