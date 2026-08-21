//
//  VMRunningRegistry.swift
//  EasyVM
//
//  Created by everettjf on 2026/8/18.
//

import Foundation
import Observation

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
    }

    private var entries: [String: Entry] = [:]

    init() {}

    var runningRootPaths: Set<URL> {
        Set(entries.keys.map { URL(fileURLWithPath: $0, isDirectory: true) })
    }

    @discardableResult
    func acquire(rootPath: URL) -> VMRunLease? {
        let key = canonicalKey(rootPath)
        guard entries[key] == nil else { return nil }
        let lease = VMRunLease(id: UUID(), rootPath: URL(fileURLWithPath: key))
        entries[key] = Entry(leaseID: lease.id, phase: .starting)
        return lease
    }

    func transition(_ lease: VMRunLease, to phase: VMRunPhase) {
        let key = canonicalKey(lease.rootPath)
        guard var entry = entries[key], entry.leaseID == lease.id else { return }
        entry.phase = phase
        entries[key] = entry
    }

    func release(_ lease: VMRunLease) {
        let key = canonicalKey(lease.rootPath)
        guard entries[key]?.leaseID == lease.id else { return }
        entries.removeValue(forKey: key)
    }

    func phase(rootPath: URL) -> VMRunPhase? {
        entries[canonicalKey(rootPath)]?.phase
    }

    func isRunning(rootPath: URL) -> Bool {
        entries[canonicalKey(rootPath)] != nil
    }

    private func canonicalKey(_ rootPath: URL) -> String {
        var path = rootPath.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false)
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }
}

#endif
