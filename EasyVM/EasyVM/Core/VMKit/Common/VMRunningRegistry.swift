//
//  VMRunningRegistry.swift
//  EasyVM
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
    }

    private var entries: [String: Entry] = [:]
    private let lockDirectory: URL

    init(lockDirectory: URL? = nil) {
        self.lockDirectory = lockDirectory ?? FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0].appendingPathComponent("EasyVM/RunLeases", isDirectory: true)
    }

    var runningRootPaths: Set<URL> {
        Set(entries.keys.map { URL(fileURLWithPath: $0, isDirectory: true) })
    }

    @discardableResult
    func acquire(rootPath: URL) -> VMRunLease? {
        let key = canonicalKey(rootPath)
        guard entries[key] == nil else { return nil }
        guard let descriptor = acquireCrossProcessLock(key: key) else { return nil }
        let lease = VMRunLease(id: UUID(), rootPath: URL(fileURLWithPath: key))
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        entries[key] = Entry(leaseID: lease.id, phase: .starting, lockHandle: handle, usage: nil)
        writeRecord(key: key, entry: entries[key]!)
        return lease
    }

    func configureResources(_ lease: VMRunLease, cpuCount: Int, memoryBytes: UInt64,
                            policy: VMHostResourcePolicy? = nil) -> VMResourceAssessment? {
        let key = canonicalKey(lease.rootPath)
        guard var entry = entries[key], entry.leaseID == lease.id else { return nil }
        let requested = VMResourceUsage(cpuCount: cpuCount, memoryBytes: memoryBytes)
        let effectivePolicy = policy ?? VMHostResourcePolicy(
            hostCPUCount: ProcessInfo.processInfo.processorCount,
            hostMemoryBytes: ProcessInfo.processInfo.physicalMemory
        )
        let assessment = effectivePolicy.assess(existing: activeExternalUsage(excluding: key), requested: requested)
        guard assessment.allowed else { return assessment }
        entry.usage = requested
        entries[key] = entry
        writeRecord(key: key, entry: entry)
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
        try? FileManager.default.createDirectory(at: lockDirectory, withIntermediateDirectories: true)
        let descriptor = open(lockURL(key: key).path, O_RDWR | O_CREAT | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { return nil }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
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

    private func writeRecord(key: String, entry: Entry) {
        let record = DiskRecord(schemaVersion: 1, pid: getpid(), machinePath: key, phase: entry.phase,
                                cpuCount: entry.usage?.cpuCount, memoryBytes: entry.usage?.memoryBytes,
                                updatedAt: Date())
        guard let data = try? JSONEncoder().encode(record) else { return }
        let descriptor = entry.lockHandle.fileDescriptor
        guard ftruncate(descriptor, 0) == 0, lseek(descriptor, 0, SEEK_SET) >= 0 else { return }
        data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, base.advanced(by: offset), bytes.count - offset)
                if count <= 0 { return }
                offset += count
            }
        }
    }

    private func activeExternalUsage(excluding key: String) -> [VMResourceUsage] {
        let own = entries.compactMap { $0.key == key ? nil : $0.value.usage }
        guard let files = try? FileManager.default.contentsOfDirectory(at: lockDirectory,
                                                                       includingPropertiesForKeys: nil) else { return own }
        var result = own
        for file in files where file.pathExtension == "lock" && file != lockURL(key: key) {
            let descriptor = open(file.path, O_RDONLY | O_CLOEXEC)
            guard descriptor >= 0 else { continue }
            let locked = flock(descriptor, LOCK_EX | LOCK_NB) != 0 && errno == EWOULDBLOCK
            if !locked { flock(descriptor, LOCK_UN) }
            close(descriptor)
            guard locked, let data = try? Data(contentsOf: file),
                  let record = try? JSONDecoder().decode(DiskRecord.self, from: data),
                  let cpu = record.cpuCount, let memory = record.memoryBytes else { continue }
            // Entries owned by this registry were already counted above.
            if entries[record.machinePath] == nil {
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
