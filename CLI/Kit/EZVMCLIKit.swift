import Foundation
import CryptoKit
import Darwin

enum EZVMExecutableLocation {
    static func resolved(_ path: String, environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if path.contains("/") {
            return URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        }
        for directory in environment["PATH", default: ""].split(separator: ":", omittingEmptySubsequences: false) {
            let root = directory.isEmpty ? FileManager.default.currentDirectoryPath : String(directory)
            let candidate = URL(fileURLWithPath: root).appendingPathComponent(path)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate.standardizedFileURL.resolvingSymlinksInPath()
            }
        }
        return URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
    }

    static func hostAppExecutable(
        for path: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> URL? {
        let helperDirectory = resolved(path, environment: environment).deletingLastPathComponent()
        let appExecutable = helperDirectory.deletingLastPathComponent().appendingPathComponent("MacOS/EZVM")
        return fileManager.isExecutableFile(atPath: appExecutable.path) ? appExecutable : nil
    }
}

public enum EZVMCLIExit: Int32, Sendable {
    case success = 0
    case invalidArguments = 64
    case notFound = 66
    case invalidMachine = 65
    case unavailable = 69
    case internalError = 70
}

public struct EZVMCLIResponse: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let command: String
    public let success: Bool
    public let result: JSONValue?
    public let error: EZVMCLIErrorPayload?

    public init(command: String, result: JSONValue) {
        schemaVersion = 1
        self.command = command
        success = true
        self.result = result
        error = nil
    }

    public init(command: String, code: String, message: String) {
        schemaVersion = 1
        self.command = command
        success = false
        result = nil
        error = EZVMCLIErrorPayload(code: code, message: message)
    }
}

public struct EZVMCLIErrorPayload: Codable, Equatable, Sendable {
    public let code: String
    public let message: String
}

public enum JSONValue: Codable, Equatable, Sendable {
    case string(String), number(Double), bool(Bool), object([String: JSONValue]), array([JSONValue]), null

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let item = try? value.decode(Bool.self) { self = .bool(item) }
        else if let item = try? value.decode(Double.self) { self = .number(item) }
        else if let item = try? value.decode(String.self) { self = .string(item) }
        else if let item = try? value.decode([String: JSONValue].self) { self = .object(item) }
        else { self = .array(try value.decode([JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .string(let item): try value.encode(item)
        case .number(let item): try value.encode(item)
        case .bool(let item): try value.encode(item)
        case .object(let item): try value.encode(item)
        case .array(let item): try value.encode(item)
        case .null: try value.encodeNil()
        }
    }
}

public struct EZVMMachineSummary: Codable, Equatable, Sendable {
    public let name: String
    public let path: String
    public let osType: String
    public let cpuCount: Int?
    public let memoryBytes: UInt64?
    public let valid: Bool
    public let problems: [String]
}

public struct EZVMHeadlessRecord: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let pid: Int32
    public let machinePath: String
    public let phase: String
    public let message: String?
    public let updatedAt: Date
    public let launchToken: String
}

public struct EZVMPreinstalledImageManifest: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public static let manifestKind = "io.github.everettjf.ezvm.preinstalled-image"

    public struct Product: Codable, Equatable, Sendable {
        public let id: String
        public let name: String
        public let version: String
    }

    public struct Disk: Codable, Equatable, Sendable {
        public let format: String
        public let virtualSize: UInt64
        public let sha256: String
    }

    public struct VirtualMachine: Codable, Equatable, Sendable {
        public let name: String
        public let remark: String?
    }

    public let schemaVersion: Int
    public let kind: String
    public let architecture: String
    public let minimumEZVMVersion: String
    public let product: Product
    public let disk: Disk
    public let virtualMachine: VirtualMachine

    public func validate(minimumDiskSize: UInt64 = 10 * 1024 * 1024 * 1024) throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw ValidationError("Unsupported preinstalled-image manifest schema version: \(schemaVersion).")
        }
        guard kind == Self.manifestKind else { throw ValidationError("Unsupported manifest kind: \(kind).") }
        guard architecture == "arm64" else { throw ValidationError("Only arm64 preinstalled images are supported.") }
        guard disk.format == "raw" else { throw ValidationError("Only raw preinstalled disks are supported.") }
        guard disk.virtualSize >= minimumDiskSize else {
            throw ValidationError("The manifest disk is smaller than the supported minimum.")
        }
        guard disk.sha256.count == 64, disk.sha256.allSatisfy({ $0.isHexDigit }) else {
            throw ValidationError("The manifest disk SHA-256 is invalid.")
        }
        guard !product.id.isEmpty, !product.name.isEmpty, !product.version.isEmpty,
              !virtualMachine.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ValidationError("The manifest product and virtual-machine identity must not be empty.")
        }
        guard Self.isVersion(minimumEZVMVersion, atMost: Self.runningVersion) else {
            throw ValidationError("This image requires EZVM \(minimumEZVMVersion) or newer; this installation is \(Self.runningVersion).")
        }
    }

    public static func load(from url: URL, minimumDiskSize: UInt64 = 10 * 1024 * 1024 * 1024) throws -> Self {
        let value = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        try value.validate(minimumDiskSize: minimumDiskSize)
        return value
    }

    public static var runningVersion: String {
        if let override = ProcessInfo.processInfo.environment["EZVM_VERSION"], !override.isEmpty { return override }
        if let bundled = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String { return bundled }
        let executable = EZVMExecutableLocation.resolved(CommandLine.arguments[0])
        let appInfo = executable.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Info.plist")
        if let values = NSDictionary(contentsOf: appInfo),
           let appVersion = values["CFBundleShortVersionString"] as? String { return appVersion }
        return "1.0.0"
    }

    private static func isVersion(_ required: String, atMost actual: String) -> Bool {
        let requiredParts = required.split(separator: ".").map { Int($0) ?? -1 }
        let actualParts = actual.split(separator: ".").map { Int($0) ?? -1 }
        guard !requiredParts.contains(-1), !actualParts.contains(-1) else { return false }
        for index in 0..<max(requiredParts.count, actualParts.count) {
            let lhs = index < requiredParts.count ? requiredParts[index] : 0
            let rhs = index < actualParts.count ? actualParts[index] : 0
            if lhs != rhs { return rhs > lhs }
        }
        return true
    }

    public struct ValidationError: LocalizedError, Equatable {
        public let message: String
        public init(_ message: String) { self.message = message }
        public var errorDescription: String? { message }
    }
}

private struct EZVMSharedRuntimeRecord: Codable {
    let schemaVersion: Int
    let pid: Int32
    let machinePath: String
    let phase: String
    let cpuCount: Int?
    let memoryBytes: UInt64?
    let updatedAt: Date
    let launchID: UUID
    let mode: String
}

public struct EZVMMachineInspector {
    public static let bundleExtensions = ["ezvm"]
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) { self.fileManager = fileManager }

    public func discover(roots: [URL]) -> [URL] {
        var seen = Set<String>()
        var machines: [URL] = []
        for root in roots {
            let root = root.standardizedFileURL
            guard let children = try? fileManager.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for child in children {
                guard let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                      values.isDirectory == true, values.isSymbolicLink != true,
                      fileManager.fileExists(atPath: child.appendingPathComponent("config.json").path) else { continue }
                let path = child.standardizedFileURL.path
                if seen.insert(path).inserted { machines.append(child.standardizedFileURL) }
            }
        }
        return machines.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    public func inspect(_ machineURL: URL) -> EZVMMachineSummary {
        let url = machineURL.standardizedFileURL
        var problems: [String] = []
        if isSymbolicLink(url) { problems.append("machine path is a symbolic link") }
        let configURL = url.appendingPathComponent("config.json")
        guard let data = try? Data(contentsOf: configURL),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return EZVMMachineSummary(name: url.deletingPathExtension().lastPathComponent, path: url.path,
                                        osType: "unknown", cpuCount: nil, memoryBytes: nil,
                                        valid: false, problems: problems + ["config.json is missing or invalid JSON"])
        }
        let name = raw["name"] as? String ?? url.deletingPathExtension().lastPathComponent
        let type = raw["type"] as? String ?? "unknown"
        if !["macOS", "linux"].contains(type) { problems.append("unsupported guest type: \(type)") }
        let cpu = integer(in: raw["cpu"])
        let memory = unsignedInteger(in: raw["memory"])
        if cpu == nil || cpu == 0 { problems.append("CPU count is missing or zero") }
        if memory == nil || memory == 0 { problems.append("memory size is missing or zero") }
        validateReferencedFiles(raw: raw, root: url, problems: &problems)
        return EZVMMachineSummary(name: name, path: url.path, osType: type, cpuCount: cpu,
                                    memoryBytes: memory, valid: problems.isEmpty, problems: problems.sorted())
    }

    public func resolve(_ target: String, roots: [URL]) throws -> URL {
        let explicit = URL(fileURLWithPath: target)
        if target.contains("/") || explicit.path == target, fileManager.fileExists(atPath: explicit.path) {
            return explicit.standardizedFileURL
        }
        let matches = discover(roots: roots).filter {
            $0.lastPathComponent == target || $0.deletingPathExtension().lastPathComponent == target
        }
        guard matches.count == 1 else {
            if matches.isEmpty { throw InspectionError.notFound(target) }
            throw InspectionError.ambiguous(target)
        }
        return matches[0]
    }

    private func validateReferencedFiles(raw: [String: Any], root: URL, problems: inout [String]) {
        guard let devices = raw["storageDevices"] as? [[String: Any]] else {
            problems.append("storageDevices is missing")
            return
        }
        for device in devices {
            guard let path = device["imagePath"] as? String, !path.isEmpty else {
                problems.append("a storage device has no imagePath")
                continue
            }
            let isAbsolute = path.hasPrefix("/")
            if !isAbsolute, path.split(separator: "/").contains("..") {
                problems.append("storage path escapes the machine bundle: \(path)")
                continue
            }
            let candidate = isAbsolute ? URL(fileURLWithPath: path) : root.appendingPathComponent(path)
            let containsSymlink = isAbsolute ? isSymbolicLink(candidate) : relativePathContainsSymlink(root: root, path: path)
            if containsSymlink {
                problems.append("storage path contains a symbolic link: \(path)")
            }
            else if !fileManager.fileExists(atPath: candidate.path) { problems.append("storage file is missing: \(path)") }
        }
    }

    private func integer(in value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let object = value as? [String: Any] {
            for key in ["count", "value", "cpuCount"] where object[key] != nil { return integer(in: object[key]) }
        }
        return nil
    }

    private func unsignedInteger(in value: Any?) -> UInt64? {
        if let number = value as? NSNumber { return number.uint64Value }
        if let object = value as? [String: Any] {
            for key in ["size", "value", "memorySize"] where object[key] != nil { return unsignedInteger(in: object[key]) }
        }
        return nil
    }

    private func relativePathContainsSymlink(root: URL, path: String) -> Bool {
        var current = root
        for component in path.split(separator: "/") {
            current.appendPathComponent(String(component))
            if isSymbolicLink(current) { return true }
        }
        return false
    }

    private func isSymbolicLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }

    public enum InspectionError: LocalizedError, Equatable {
        case notFound(String), ambiguous(String)
        public var errorDescription: String? {
            switch self {
            case .notFound(let value): "No machine matches '\(value)'."
            case .ambiguous(let value): "More than one machine matches '\(value)'; use an absolute path."
            }
        }
    }
}

public struct EZVMCLI {
    public let inspector: EZVMMachineInspector
    private let minimumPreinstalledDiskSize: UInt64
    public init(inspector: EZVMMachineInspector = .init(), minimumPreinstalledDiskSize: UInt64 = 10 * 1024 * 1024 * 1024) {
        self.inspector = inspector
        self.minimumPreinstalledDiskSize = minimumPreinstalledDiskSize
    }

    public func run(arguments: [String], environment: [String: String] = ProcessInfo.processInfo.environment) -> (EZVMCLIExit, EZVMCLIResponse) {
        let parsed: Parsed
        do { parsed = try parse(arguments: arguments, environment: environment) }
        catch { return (.invalidArguments, .init(command: "unknown", code: "invalid_arguments", message: error.localizedDescription)) }
        switch parsed.command {
        case "list":
            guard parsed.target == nil else { return unexpectedTarget("list") }
            let values = inspector.discover(roots: parsed.roots).map(inspector.inspect).map(summaryJSON)
            return (.success, .init(command: "list", result: .array(values)))
        case "inspect", "validate":
            guard let target = parsed.target else {
                return (.invalidArguments, .init(command: parsed.command, code: "invalid_arguments", message: "A machine name or path is required."))
            }
            do {
                let summary = inspector.inspect(try inspector.resolve(target, roots: parsed.roots))
                if parsed.command == "validate", !summary.valid {
                    return (.invalidMachine, .init(command: "validate", code: "invalid_machine", message: summary.problems.joined(separator: "; ")))
                }
                return (.success, .init(command: parsed.command, result: summaryJSON(summary)))
            } catch let error as EZVMMachineInspector.InspectionError {
                return (.notFound, .init(command: parsed.command, code: "machine_not_found", message: error.localizedDescription))
            } catch {
                return (.internalError, .init(command: parsed.command, code: "internal_error", message: error.localizedDescription))
            }
        case "doctor":
            guard parsed.target == nil else { return unexpectedTarget("doctor") }
            let arm64 = ProcessInfo.processInfo.machineArchitecture == "arm64"
            let os26 = ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26
            let roots = parsed.roots.map { root in
                JSONValue.object(["path": .string(root.path), "readable": .bool(FileManager.default.isReadableFile(atPath: root.path))])
            }
            return (arm64 && os26 ? .success : .unavailable, .init(command: "doctor", result: .object([
                "architecture": .string(ProcessInfo.processInfo.machineArchitecture),
                "appleSilicon": .bool(arm64), "macOS26OrLater": .bool(os26), "roots": .array(roots)
            ])))
        case "start":
            return start(parsed)
        case "status":
            return status(parsed)
        case "stop":
            return stop(parsed)
        case "install-image":
            return installImage(parsed)
        default:
            return (.invalidArguments, .init(command: parsed.command, code: "unknown_command", message: "Unknown command '\(parsed.command)'."))
        }
    }

    public func encode(_ response: EZVMCLIResponse) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(response) + Data([0x0a])
    }

    private struct Parsed {
        let command: String
        let target: String?
        let roots: [URL]
        let timeout: TimeInterval
        let image: URL?
        let thumbnail: URL?
        let destination: URL?
        let name: String?
    }
    private func parse(arguments: [String], environment: [String: String]) throws -> Parsed {
        guard let command = arguments.first else { throw ParseError("Usage: ezvm <list|inspect|validate|doctor> [machine] [--root path]") }
        var index = 1, target: String?, roots: [URL] = []
        var timeout: TimeInterval = 30
        var image: URL?, thumbnail: URL?, destination: URL?, name: String?
        while index < arguments.count {
            if arguments[index] == "--root" {
                guard index + 1 < arguments.count else { throw ParseError("--root requires a path") }
                roots.append(URL(fileURLWithPath: arguments[index + 1])); index += 2
            } else if arguments[index] == "--timeout" {
                guard index + 1 < arguments.count, let value = Double(arguments[index + 1]), value >= 1, value <= 300 else {
                    throw ParseError("--timeout must be between 1 and 300 seconds")
                }
                timeout = value; index += 2
            } else if arguments[index] == "--image" {
                guard index + 1 < arguments.count else { throw ParseError("--image requires a path") }
                image = URL(fileURLWithPath: arguments[index + 1]).standardizedFileURL; index += 2
            } else if arguments[index] == "--thumbnail" {
                guard index + 1 < arguments.count else { throw ParseError("--thumbnail requires a path") }
                thumbnail = URL(fileURLWithPath: arguments[index + 1]).standardizedFileURL; index += 2
            } else if arguments[index] == "--destination" {
                guard index + 1 < arguments.count else { throw ParseError("--destination requires a path") }
                destination = URL(fileURLWithPath: arguments[index + 1]).standardizedFileURL; index += 2
            } else if arguments[index] == "--name" {
                guard index + 1 < arguments.count, !arguments[index + 1].isEmpty else { throw ParseError("--name requires a value") }
                name = arguments[index + 1]; index += 2
            } else if target == nil { target = arguments[index]; index += 1 }
            else { throw ParseError("Unexpected argument: \(arguments[index])") }
        }
        if roots.isEmpty {
            let home = environment["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path
            roots = [URL(fileURLWithPath: home).appendingPathComponent("EZVM Virtual Machines")]
        }
        return Parsed(command: command, target: target, roots: roots, timeout: timeout,
                      image: image, thumbnail: thumbnail, destination: destination, name: name)
    }

    private func installImage(_ parsed: Parsed) -> (EZVMCLIExit, EZVMCLIResponse) {
        guard let manifestPath = parsed.target, let image = parsed.image, let destination = parsed.destination else {
            return (.invalidArguments, .init(command: "install-image", code: "invalid_arguments",
                message: "Usage: ezvm install-image <manifest.json> --image <disk.raw> --destination <machine.ezvm> [--thumbnail image.png] [--name name] [--timeout seconds]"))
        }
        let manifestURL = URL(fileURLWithPath: manifestPath).standardizedFileURL
        guard destination.pathExtension.lowercased() == "ezvm" else {
            return (.invalidArguments, .init(command: "install-image", code: "invalid_destination", message: "Destination must use the .ezvm extension."))
        }
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            return (.invalidMachine, .init(command: "install-image", code: "destination_exists", message: "Destination already exists: \(destination.path)"))
        }
        do {
            let manifest = try EZVMPreinstalledImageManifest.load(from: manifestURL, minimumDiskSize: minimumPreinstalledDiskSize)
            let values = try image.resourceValues(forKeys: [.fileSizeKey])
            guard UInt64(values.fileSize ?? 0) == manifest.disk.virtualSize else {
                return (.invalidMachine, .init(command: "install-image", code: "image_size_mismatch", message: "Disk image size does not match the manifest."))
            }
            guard try sha256(of: image) == manifest.disk.sha256.lowercased() else {
                return (.invalidMachine, .init(command: "install-image", code: "image_checksum_mismatch", message: "Disk image SHA-256 does not match the manifest."))
            }
            if let thumbnail = parsed.thumbnail,
               !FileManager.default.isReadableFile(atPath: thumbnail.path) {
                return (.invalidMachine, .init(command: "install-image", code: "invalid_thumbnail", message: "Thumbnail image is not readable: \(thumbnail.path)"))
            }
            guard let executable = hostAppExecutable() else {
                return (.unavailable, .init(command: "install-image", code: "host_app_unavailable", message: "Could not locate the EZVM application executable."))
            }
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            let process = Process()
            let stdout = Pipe(), stderr = Pipe()
            let stagingToken = UUID().uuidString
            process.executableURL = executable
            process.arguments = ["--ezvm-install-preinstalled-image", manifestURL.path, "--image", image.path,
                                 "--destination", destination.path, "--name", parsed.name ?? manifest.virtualMachine.name,
                                 "--staging-token", stagingToken]
            if let thumbnail = parsed.thumbnail {
                process.arguments?.append(contentsOf: ["--thumbnail", thumbnail.path])
            }
            process.standardOutput = stdout
            process.standardError = stderr
            try process.run()
            let deadline = Date().addingTimeInterval(parsed.timeout)
            while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
            if process.isRunning {
                process.terminate()
                let terminationDeadline = Date().addingTimeInterval(5)
                while process.isRunning, Date() < terminationDeadline { Thread.sleep(forTimeInterval: 0.05) }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                removeInstallArtifacts(destination: destination, stagingToken: stagingToken)
                return (.unavailable, .init(command: "install-image", code: "install_timeout", message: "Image installation did not finish within \(Int(parsed.timeout)) seconds; partial output was removed."))
            }
            let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
            guard process.terminationStatus == 0 else {
                removeInstallArtifacts(destination: destination, stagingToken: stagingToken)
                let message = String(decoding: errorData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                return (.internalError, .init(command: "install-image", code: "install_failed", message: message.isEmpty ? "EZVM could not install the image." : message))
            }
            return (.success, .init(command: "install-image", result: .object([
                "manifest": .string(manifestURL.path), "image": .string(image.path),
                "destination": .string(destination.path), "name": .string(parsed.name ?? manifest.virtualMachine.name),
                "productID": .string(manifest.product.id), "productVersion": .string(manifest.product.version)
            ])))
        } catch let error as EZVMPreinstalledImageManifest.ValidationError {
            return (.invalidMachine, .init(command: "install-image", code: "invalid_manifest", message: error.localizedDescription))
        } catch {
            return (.internalError, .init(command: "install-image", code: "install_failed", message: error.localizedDescription))
        }
    }

    private func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let data = try handle.read(upToCount: 4 * 1024 * 1024) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func removeInstallArtifacts(destination: URL, stagingToken: String) {
        try? FileManager.default.removeItem(at: destination)
        let staging = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).install-\(stagingToken)", isDirectory: true)
        try? FileManager.default.removeItem(at: staging)
    }

    private func start(_ parsed: Parsed) -> (EZVMCLIExit, EZVMCLIResponse) {
        guard let target = parsed.target else { return missingTarget("start") }
        do {
            let machine = try inspector.resolve(target, roots: parsed.roots)
            let summary = inspector.inspect(machine)
            guard summary.valid else {
                return (.invalidMachine, .init(command: "start", code: "invalid_machine", message: summary.problems.joined(separator: "; ")))
            }
            let stateURL = headlessStateURL(for: machine)
            if let record = readHeadlessState(stateURL), isExpectedHeadlessProcess(record, machine: machine) {
                return (.invalidMachine, .init(command: "start", code: "already_running", message: "The machine already has a headless process."))
            }
            try? FileManager.default.removeItem(at: stateURL)
            guard let executable = hostAppExecutable() else {
                return (.unavailable, .init(command: "start", code: "host_app_unavailable", message: "Could not locate the EZVM application executable."))
            }
            let process = Process()
            let launchToken = UUID().uuidString
            process.executableURL = executable
            process.arguments = ["--ezvm-headless", machine.path, "--state-file", stateURL.path,
                                 "--launch-token", launchToken]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            let deadline = Date().addingTimeInterval(parsed.timeout)
            while Date() < deadline {
                if let record = readHeadlessState(stateURL), record.pid == process.processIdentifier,
                   record.launchToken == launchToken {
                    if record.phase == "running" || record.phase == "paused" {
                        return (.success, .init(command: "start", result: headlessJSON(record)))
                    }
                    if record.phase == "failed" {
                        return (.internalError, .init(command: "start", code: "start_failed", message: record.message ?? "The virtual machine failed to start."))
                    }
                }
                if !process.isRunning { break }
                Thread.sleep(forTimeInterval: 0.1)
            }
            if process.isRunning { kill(process.processIdentifier, SIGTERM) }
            return (.unavailable, .init(command: "start", code: "start_timeout", message: "The virtual machine did not reach running state within \(Int(parsed.timeout)) seconds."))
        } catch let error as EZVMMachineInspector.InspectionError {
            return (.notFound, .init(command: "start", code: "machine_not_found", message: error.localizedDescription))
        } catch {
            return (.internalError, .init(command: "start", code: "start_failed", message: error.localizedDescription))
        }
    }

    private func status(_ parsed: Parsed) -> (EZVMCLIExit, EZVMCLIResponse) {
        guard let target = parsed.target else { return missingTarget("status") }
        do {
            let machine = try inspector.resolve(target, roots: parsed.roots)
            guard let record = readHeadlessState(headlessStateURL(for: machine)), isExpectedHeadlessProcess(record, machine: machine) else {
                if let shared = readActiveSharedRuntime(for: machine) {
                    return (.success, .init(command: "status", result: sharedRuntimeJSON(shared)))
                }
                return (.success, .init(command: "status", result: .object([
                    "machinePath": .string(machine.path), "phase": .string("stopped")
                ])))
            }
            return (.success, .init(command: "status", result: headlessJSON(record)))
        } catch let error as EZVMMachineInspector.InspectionError {
            return (.notFound, .init(command: "status", code: "machine_not_found", message: error.localizedDescription))
        } catch {
            return (.internalError, .init(command: "status", code: "internal_error", message: error.localizedDescription))
        }
    }

    private func stop(_ parsed: Parsed) -> (EZVMCLIExit, EZVMCLIResponse) {
        guard let target = parsed.target else { return missingTarget("stop") }
        do {
            let machine = try inspector.resolve(target, roots: parsed.roots)
            let stateURL = headlessStateURL(for: machine)
            guard let record = readHeadlessState(stateURL), isExpectedHeadlessProcess(record, machine: machine) else {
                try? FileManager.default.removeItem(at: stateURL)
                return (.notFound, .init(command: "stop", code: "not_running", message: "The machine has no active headless process."))
            }
            guard kill(record.pid, SIGTERM) == 0 else {
                return (.internalError, .init(command: "stop", code: "signal_failed", message: String(cString: strerror(errno))))
            }
            let deadline = Date().addingTimeInterval(parsed.timeout)
            while Date() < deadline {
                if let updated = readHeadlessState(stateURL), updated.phase == "stopped" {
                    return (.success, .init(command: "stop", result: headlessJSON(updated)))
                }
                if kill(record.pid, 0) != 0 { break }
                Thread.sleep(forTimeInterval: 0.1)
            }
            if kill(record.pid, 0) != 0 {
                return (.success, .init(command: "stop", result: .object([
                    "machinePath": .string(machine.path), "phase": .string("stopped")
                ])))
            }
            return (.unavailable, .init(command: "stop", code: "stop_timeout", message: "The guest did not stop within \(Int(parsed.timeout)) seconds."))
        } catch let error as EZVMMachineInspector.InspectionError {
            return (.notFound, .init(command: "stop", code: "machine_not_found", message: error.localizedDescription))
        } catch {
            return (.internalError, .init(command: "stop", code: "internal_error", message: error.localizedDescription))
        }
    }

    private func missingTarget(_ command: String) -> (EZVMCLIExit, EZVMCLIResponse) {
        (.invalidArguments, .init(command: command, code: "invalid_arguments", message: "A machine name or path is required."))
    }

    private func unexpectedTarget(_ command: String) -> (EZVMCLIExit, EZVMCLIResponse) {
        (.invalidArguments, .init(command: command, code: "invalid_arguments", message: "The \(command) command does not accept a machine target."))
    }

    private func headlessStateURL(for machine: URL) -> URL {
        let digest = SHA256.hash(data: Data(machine.standardizedFileURL.path.utf8)).map { String(format: "%02x", $0) }.joined()
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("EZVM/Headless", isDirectory: true)
        return base.appendingPathComponent("\(digest).json")
    }

    private func readHeadlessState(_ url: URL) -> EZVMHeadlessRecord? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(EZVMHeadlessRecord.self, from: data)
    }

    private func hostAppExecutable() -> URL? {
        if let override = ProcessInfo.processInfo.environment["EZVM_APP_EXECUTABLE"],
           FileManager.default.isExecutableFile(atPath: override) { return URL(fileURLWithPath: override) }
        return EZVMExecutableLocation.hostAppExecutable(for: CommandLine.arguments[0])
    }

    private func isExpectedHeadlessProcess(_ record: EZVMHeadlessRecord, machine: URL) -> Bool {
        let pid = record.pid
        guard record.schemaVersion == 2, !record.launchToken.isEmpty,
              URL(fileURLWithPath: record.machinePath).standardizedFileURL == machine.standardizedFileURL,
              isExpectedAppProcess(pid) else { return false }
        return true
    }

    private func isExpectedAppProcess(_ pid: Int32) -> Bool {
        guard pid > 1, kill(pid, 0) == 0 else { return false }
        var buffer = [CChar](repeating: 0, count: 4096)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return false }
        guard let expected = hostAppExecutable()?.resolvingSymlinksInPath().standardizedFileURL else { return false }
        return URL(fileURLWithPath: String(cString: buffer)).resolvingSymlinksInPath().standardizedFileURL == expected
    }

    private func readActiveSharedRuntime(for machine: URL) -> EZVMSharedRuntimeRecord? {
        let key = machine.standardizedFileURL.resolvingSymlinksInPath().path
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("EZVM/RunLeases", isDirectory: true)
        let lockURL = base.appendingPathComponent("\(digest).lock")
        let metadataURL = base.appendingPathComponent("\(digest).json")
        let descriptor = open(lockURL.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
            flock(descriptor, LOCK_UN)
            return nil
        }
        guard errno == EWOULDBLOCK, let data = try? Data(contentsOf: metadataURL),
              let record = try? JSONDecoder().decode(EZVMSharedRuntimeRecord.self, from: data),
              record.schemaVersion == 1, record.machinePath == key,
              isExpectedAppProcess(record.pid) else { return nil }
        return record
    }

    private func sharedRuntimeJSON(_ value: EZVMSharedRuntimeRecord) -> JSONValue {
        .object(["pid": .number(Double(value.pid)), "machinePath": .string(value.machinePath),
                 "phase": .string(value.phase), "mode": .string(value.mode),
                 "cpuCount": value.cpuCount.map { .number(Double($0)) } ?? .null,
                 "memoryBytes": value.memoryBytes.map { .number(Double($0)) } ?? .null,
                 "updatedAt": .string(ISO8601DateFormatter().string(from: value.updatedAt))])
    }

    private func headlessJSON(_ value: EZVMHeadlessRecord) -> JSONValue {
        .object(["pid": .number(Double(value.pid)), "machinePath": .string(value.machinePath),
                 "phase": .string(value.phase), "message": value.message.map(JSONValue.string) ?? .null,
                 "updatedAt": .string(ISO8601DateFormatter().string(from: value.updatedAt))])
    }

    private func summaryJSON(_ value: EZVMMachineSummary) -> JSONValue {
        let runtime = readActiveSharedRuntime(for: URL(fileURLWithPath: value.path))
        return .object(["name": .string(value.name), "path": .string(value.path), "osType": .string(value.osType),
                 "cpuCount": value.cpuCount.map { .number(Double($0)) } ?? .null,
                 "memoryBytes": value.memoryBytes.map { .number(Double($0)) } ?? .null,
                 "runtimePhase": runtime.map { .string($0.phase) } ?? .string("stopped"),
                 "runtimePID": runtime.map { .number(Double($0.pid)) } ?? .null,
                 "valid": .bool(value.valid), "problems": .array(value.problems.map(JSONValue.string))])
    }
    private struct ParseError: LocalizedError { let message: String; init(_ message: String) { self.message = message }; var errorDescription: String? { message } }
}

private extension ProcessInfo {
    var machineArchitecture: String {
        var value = utsname(); uname(&value)
        return withUnsafePointer(to: &value.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
    }
}
