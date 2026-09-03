import Foundation

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
        return .ready
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

    private func createSupportDirectories() throws {
        for directory in [layout.enrollment, layout.shared, layout.cache, layout.diagnostics] {
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
