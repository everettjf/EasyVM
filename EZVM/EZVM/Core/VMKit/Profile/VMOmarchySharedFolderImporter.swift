import Foundation

public struct VMOmarchyImportedFile: Equatable, Sendable {
    public let sourceName: String
    public let destinationURL: URL

    public init(sourceName: String, destinationURL: URL) {
        self.sourceName = sourceName
        self.destinationURL = destinationURL
    }
}

public enum VMOmarchySharedFolderImportError: Error, Equatable, LocalizedError {
    case sharedFolderUnavailable
    case unsupportedSource(String)
    case importFailed(String)

    public var errorDescription: String? {
        switch self {
        case .sharedFolderUnavailable:
            "The managed Omarchy shared folder is unavailable or unsafe."
        case .unsupportedSource(let name):
            "\(name) is not a regular file or is a symbolic link."
        case .importFailed(let reason):
            "The file could not be imported into Omarchy: \(reason)"
        }
    }
}

/// Copies user-selected files into the product-owned VirtioFS directory.
/// Publication is atomic and never replaces an existing item.
public struct VMOmarchySharedFolderImporter {
    public let layout: VMOmarchyWorkspaceLayout
    private let fileManager: FileManager

    public init(layout: VMOmarchyWorkspaceLayout, fileManager: FileManager = .default) {
        self.layout = layout
        self.fileManager = fileManager
    }

    public func importFiles(_ sources: [URL]) throws -> [VMOmarchyImportedFile] {
        guard directoryIsSafe(layout.applicationSupportRoot), directoryIsSafe(layout.shared) else {
            throw VMOmarchySharedFolderImportError.sharedFolderUnavailable
        }
        var imported: [VMOmarchyImportedFile] = []
        for source in sources {
            guard regularFileIsSafe(source) else {
                throw VMOmarchySharedFolderImportError.unsupportedSource(source.lastPathComponent)
            }
            let destination = uniqueDestination(for: source.lastPathComponent)
            let staging = layout.shared.appending(path: ".importing.\(UUID().uuidString)")
            do {
                try fileManager.copyItem(at: source, to: staging)
                try fileManager.moveItem(at: staging, to: destination)
                imported.append(VMOmarchyImportedFile(
                    sourceName: source.lastPathComponent,
                    destinationURL: destination
                ))
            } catch {
                try? fileManager.removeItem(at: staging)
                throw VMOmarchySharedFolderImportError.importFailed(error.localizedDescription)
            }
        }
        return imported
    }

    private func uniqueDestination(for fileName: String) -> URL {
        let source = URL(fileURLWithPath: fileName)
        let stem = source.deletingPathExtension().lastPathComponent
        let fileExtension = source.pathExtension
        var candidate = layout.shared.appending(path: fileName)
        var copyNumber = 2
        while fileManager.fileExists(atPath: candidate.path) {
            let suffix = "\(stem) copy \(copyNumber)"
            candidate = layout.shared.appending(
                path: fileExtension.isEmpty ? suffix : "\(suffix).\(fileExtension)"
            )
            copyNumber += 1
        }
        return candidate
    }

    private func directoryIsSafe(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
            && !isSymbolicLink(url)
    }

    private func regularFileIsSafe(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && !isDirectory.boolValue
            && !isSymbolicLink(url)
    }

    private func isSymbolicLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }
}
