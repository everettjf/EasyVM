import Foundation

public struct VirGLRuntimeDependencies: Sendable, Equatable {
    public static let environmentOverrideKey = "EZVM_VIRGL_RUNTIME_DIRECTORY"
    public static let bundledDirectoryName = "VirGLRuntime"

    public let directoryURL: URL
    public let virglRendererURL: URL
    public let epoxyURL: URL
    public let eglURL: URL
    public let glesURL: URL

    public init(directoryURL: URL) {
        self.directoryURL = directoryURL
        virglRendererURL = directoryURL.appending(path: "libvirglrenderer.1.dylib")
        epoxyURL = directoryURL.appending(path: "libepoxy.0.dylib")
        eglURL = directoryURL.appending(path: "libEGL.dylib")
        glesURL = directoryURL.appending(path: "libGLESv2.dylib")
    }

    public static func resolve(
        bundle: Bundle = .main,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> VirGLRuntimeDependencies {
        if let override = environment[environmentOverrideKey], !override.isEmpty {
            return VirGLRuntimeDependencies(directoryURL: URL(fileURLWithPath: override))
        }
        let frameworks = bundle.privateFrameworksURL
            ?? bundle.bundleURL.appending(path: "Contents/Frameworks", directoryHint: .isDirectory)
        return VirGLRuntimeDependencies(
            directoryURL: frameworks.appending(path: bundledDirectoryName, directoryHint: .isDirectory)
        )
    }

    public func validate(fileManager: FileManager = .default) throws {
        let required = [virglRendererURL, epoxyURL, eglURL, glesURL]
        let missing = required.filter { !fileManager.isReadableFile(atPath: $0.path) }
        guard missing.isEmpty else {
            throw DependencyError.missing(missing.map(\.lastPathComponent))
        }
    }

    public enum DependencyError: Error, CustomStringConvertible, Equatable {
        case missing([String])

        public var description: String {
            switch self {
            case let .missing(names):
                "VirGL runtime is incomplete; missing: \(names.sorted().joined(separator: ", "))."
            }
        }
    }
}
