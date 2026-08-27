import Foundation
import CryptoKit
import Darwin

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
    public init(inspector: EZVMMachineInspector = .init()) { self.inspector = inspector }

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
        default:
            return (.invalidArguments, .init(command: parsed.command, code: "unknown_command", message: "Unknown command '\(parsed.command)'."))
        }
    }

    public func encode(_ response: EZVMCLIResponse) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(response) + Data([0x0a])
    }

    private struct Parsed { let command: String; let target: String?; let roots: [URL]; let timeout: TimeInterval }
    private func parse(arguments: [String], environment: [String: String]) throws -> Parsed {
        guard let command = arguments.first else { throw ParseError("Usage: ezvm <list|inspect|validate|doctor> [machine] [--root path]") }
        var index = 1, target: String?, roots: [URL] = []
        var timeout: TimeInterval = 30
        while index < arguments.count {
            if arguments[index] == "--root" {
                guard index + 1 < arguments.count else { throw ParseError("--root requires a path") }
                roots.append(URL(fileURLWithPath: arguments[index + 1])); index += 2
            } else if arguments[index] == "--timeout" {
                guard index + 1 < arguments.count, let value = Double(arguments[index + 1]), value >= 1, value <= 300 else {
                    throw ParseError("--timeout must be between 1 and 300 seconds")
                }
                timeout = value; index += 2
            } else if target == nil { target = arguments[index]; index += 1 }
            else { throw ParseError("Unexpected argument: \(arguments[index])") }
        }
        if roots.isEmpty {
            let home = environment["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path
            roots = [URL(fileURLWithPath: home).appendingPathComponent("EZVM Virtual Machines")]
        }
        return Parsed(command: command, target: target, roots: roots, timeout: timeout)
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
        let helperDirectory = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        let appExecutable = helperDirectory.deletingLastPathComponent().appendingPathComponent("MacOS/EZVM")
        return FileManager.default.isExecutableFile(atPath: appExecutable.path) ? appExecutable : nil
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
