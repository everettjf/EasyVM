//
//  VMRunningRegistry.swift
//  EZVM
//
//  Created by everettjf on 2026/8/18.
//

import Foundation
import Observation
import CryptoKit
import Darwin

#if arch(arm64)

/*
 Tracks which virtual machines currently have a running window, so
 destructive file operations (snapshot create/restore) can refuse to touch
 a machine that is in use.

 Registration is best effort: a machine counts as running from a
 successful start until its guest stops or its window disappears.
 */
enum VMRunPhase: String, Codable, Sendable {
    case starting
    case running
    case stopping
    case maintaining
}

struct VMResourceUsage: Codable, Equatable, Sendable {
    let cpuCount: Int
    let memoryBytes: UInt64
}

struct VMResourceAssessment: Equatable, Sendable {
    let allowed: Bool
    let warnings: [String]
    let projected: VMResourceUsage
    let denialReason: String?
}

struct VMHostResourcePolicy: Sendable {
    let hostCPUCount: Int
    let hostMemoryBytes: UInt64

    func assess(existing: [VMResourceUsage], requested: VMResourceUsage) -> VMResourceAssessment {
        let usedCPU = existing.reduce(0) { $0 + $1.cpuCount }
        let usedMemory = existing.reduce(UInt64(0)) { $0 &+ $1.memoryBytes }
        let projected = VMResourceUsage(cpuCount: usedCPU + requested.cpuCount,
                                        memoryBytes: usedMemory &+ requested.memoryBytes)
        var warnings: [String] = []
        if projected.cpuCount > hostCPUCount {
            warnings.append("Virtual CPUs are overcommitted (\(projected.cpuCount) requested across running VMs; \(hostCPUCount) logical CPUs available).")
        }
        let safeMemory = hostMemoryBytes / 10 * 8
        let hardMemory = hostMemoryBytes / 10 * 9
        if projected.memoryBytes > safeMemory {
            warnings.append("Running VMs would reserve more than 80% of host memory.")
        }
        let denialReason: String?
        if requested.cpuCount <= 0 || requested.memoryBytes == 0 {
            denialReason = "The VM has an invalid CPU or memory allocation."
        } else if projected.memoryBytes > hardMemory {
            denialReason = "Starting this VM would reserve more than 90% of host memory. Stop another VM or reduce its memory allocation."
        } else if projected.cpuCount > hostCPUCount * 2 {
            denialReason = "Starting this VM would allocate more than twice the host's logical CPU count across running VMs. Stop another VM or reduce its CPU allocation."
        } else {
            denialReason = nil
        }
        return VMResourceAssessment(allowed: denialReason == nil, warnings: warnings,
                                    projected: projected, denialReason: denialReason)
    }
}

extension VMRunPhase {
    var cardLabel: String {
        switch self {
        case .starting: "Starting"
        case .running: "Running"
        case .stopping: "Saving State"
        case .maintaining: "Maintenance"
        }
    }
}

struct VMRunLease: Equatable, Sendable {
    let id: UUID
    let rootPath: URL
}

@MainActor
@Observable
final class VMRunningRegistry {
    static let shared = VMRunningRegistry()

    private struct Entry {
        let leaseID: UUID
        var phase: VMRunPhase
        let lockHandle: FileHandle
        var usage: VMResourceUsage?
    }

    private struct DiskRecord: Codable {
        let schemaVersion: Int
        let pid: Int32
        let machinePath: String
        let phase: VMRunPhase
        let cpuCount: Int?
        let memoryBytes: UInt64?
        let updatedAt: Date
        let launchID: UUID
        let mode: String
    }

    private var entries: [String: Entry] = [:]
    private let lockDirectory: URL

    init(lockDirectory: URL? = nil) {
        self.lockDirectory = lockDirectory ?? FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0].appendingPathComponent("EZVM/RunLeases", isDirectory: true)
    }

    var runningRootPaths: Set<URL> {
        Set(entries.keys.map { URL(fileURLWithPath: $0, isDirectory: true) })
    }

    @discardableResult
    func acquire(rootPath: URL, phase: VMRunPhase = .starting) -> VMRunLease? {
        let key = canonicalKey(rootPath)
        guard entries[key] == nil else { return nil }
        guard let descriptor = acquireCrossProcessLock(key: key) else { return nil }
        let lease = VMRunLease(id: UUID(), rootPath: URL(fileURLWithPath: key))
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        entries[key] = Entry(leaseID: lease.id, phase: phase, lockHandle: handle, usage: nil)
        guard writeRecord(key: key, entry: entries[key]!) else {
            entries.removeValue(forKey: key)
            flock(descriptor, LOCK_UN)
            try? handle.close()
            return nil
        }
        return lease
    }

    func configureResources(_ lease: VMRunLease, cpuCount: Int, memoryBytes: UInt64,
                            policy: VMHostResourcePolicy? = nil) -> VMResourceAssessment? {
        let key = canonicalKey(lease.rootPath)
        guard var entry = entries[key], entry.leaseID == lease.id else { return nil }
        guard let admissionDescriptor = acquireAdmissionLock() else { return nil }
        defer {
            flock(admissionDescriptor, LOCK_UN)
            close(admissionDescriptor)
        }
        let requested = VMResourceUsage(cpuCount: cpuCount, memoryBytes: memoryBytes)
        let effectivePolicy = policy ?? VMHostResourcePolicy(
            hostCPUCount: ProcessInfo.processInfo.processorCount,
            hostMemoryBytes: ProcessInfo.processInfo.physicalMemory
        )
        guard let externalUsage = activeExternalUsage(excluding: key) else { return nil }
        let assessment = effectivePolicy.assess(existing: externalUsage, requested: requested)
        guard assessment.allowed else { return assessment }
        let previousUsage = entry.usage
        entry.usage = requested
        entries[key] = entry
        guard writeRecord(key: key, entry: entry) else {
            entry.usage = previousUsage
            entries[key] = entry
            return nil
        }
        return assessment
    }

    func transition(_ lease: VMRunLease, to phase: VMRunPhase) {
        let key = canonicalKey(lease.rootPath)
        guard var entry = entries[key], entry.leaseID == lease.id else { return }
        entry.phase = phase
        entries[key] = entry
        writeRecord(key: key, entry: entry)
    }

    func release(_ lease: VMRunLease) {
        let key = canonicalKey(lease.rootPath)
        guard let entry = entries[key], entry.leaseID == lease.id else { return }
        entries.removeValue(forKey: key)
        try? FileManager.default.removeItem(at: metadataURL(key: key))
        flock(entry.lockHandle.fileDescriptor, LOCK_UN)
        try? entry.lockHandle.close()
    }

    func phase(rootPath: URL) -> VMRunPhase? {
        entries[canonicalKey(rootPath)]?.phase
    }

    func isRunning(rootPath: URL) -> Bool {
        let key = canonicalKey(rootPath)
        return entries[key] != nil || isLockedByAnotherProcess(key: key)
    }

    private func acquireCrossProcessLock(key: String) -> Int32? {
        do {
            try FileManager.default.createDirectory(at: lockDirectory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch {
            return nil
        }
        let descriptor = open(lockURL(key: key).path, O_RDWR | O_CREAT | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { return nil }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            return nil
        }
        return descriptor
    }

    private func acquireAdmissionLock() -> Int32? {
        let descriptor = open(lockDirectory.appendingPathComponent("admission.lock").path,
                              O_RDWR | O_CREAT | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { return nil }
        guard flock(descriptor, LOCK_EX) == 0 else {
            close(descriptor)
            return nil
        }
        return descriptor
    }

    private func isLockedByAnotherProcess(key: String) -> Bool {
        let descriptor = open(lockURL(key: key).path, O_RDWR | O_CLOEXEC)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
            flock(descriptor, LOCK_UN)
            return false
        }
        return errno == EWOULDBLOCK
    }

    private func lockURL(key: String) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return lockDirectory.appendingPathComponent("\(digest).lock", isDirectory: false)
    }

    private func metadataURL(key: String) -> URL {
        lockURL(key: key).deletingPathExtension().appendingPathExtension("json")
    }

    @discardableResult
    private func writeRecord(key: String, entry: Entry) -> Bool {
        let mode = entry.phase == .maintaining ? "maintenance"
            : (ProcessInfo.processInfo.arguments.contains("--ezvm-headless") ? "headless" : "gui")
        let record = DiskRecord(schemaVersion: 1, pid: getpid(), machinePath: key, phase: entry.phase,
                                cpuCount: entry.usage?.cpuCount, memoryBytes: entry.usage?.memoryBytes,
                                updatedAt: Date(), launchID: entry.leaseID, mode: mode)
        guard let data = try? JSONEncoder().encode(record) else { return false }
        let url = metadataURL(key: key)
        do {
            try data.write(to: url, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return true
        } catch {
            return false
        }
    }

    private func activeExternalUsage(excluding key: String) -> [VMResourceUsage]? {
        let own = entries.compactMap { $0.key == key ? nil : $0.value.usage }
        guard let files = try? FileManager.default.contentsOfDirectory(at: lockDirectory,
                                                                       includingPropertiesForKeys: nil) else { return nil }
        var result = own
        for file in files where file.pathExtension == "json" && file != metadataURL(key: key) {
            let lockFile = file.deletingPathExtension().appendingPathExtension("lock")
            let descriptor = open(lockFile.path, O_RDONLY | O_CLOEXEC)
            guard descriptor >= 0 else { continue }
            let locked = flock(descriptor, LOCK_EX | LOCK_NB) != 0 && errno == EWOULDBLOCK
            if !locked { flock(descriptor, LOCK_UN) }
            close(descriptor)
            guard locked else { continue }
            guard let data = try? Data(contentsOf: file),
                  let record = try? JSONDecoder().decode(DiskRecord.self, from: data) else { return nil }
            // Entries owned by this registry were already counted above.
            if entries[record.machinePath] == nil, let cpu = record.cpuCount, let memory = record.memoryBytes {
                result.append(VMResourceUsage(cpuCount: cpu, memoryBytes: memory))
            }
        }
        return result
    }

    private func canonicalKey(_ rootPath: URL) -> String {
        var path = rootPath.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false)
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }
}

#endif
