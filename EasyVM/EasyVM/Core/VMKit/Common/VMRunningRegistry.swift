//
//  VMRunningRegistry.swift
//  EasyVM
//
//  Created by everettjf on 2026/8/18.
//

import Foundation

#if arch(arm64)

/*
 Tracks which virtual machines currently have a running window, so
 destructive file operations (snapshot create/restore) can refuse to touch
 a machine that is in use.

 Registration is best effort: a machine counts as running from a
 successful start until its guest stops or its window disappears.
 */
@MainActor
final class VMRunningRegistry: ObservableObject {
    static let shared = VMRunningRegistry()

    @Published private(set) var runningRootPaths: Set<URL> = []

    private init() {}

    func markRunning(rootPath: URL) {
        runningRootPaths.insert(rootPath.standardizedFileURL)
    }

    func markStopped(rootPath: URL) {
        runningRootPaths.remove(rootPath.standardizedFileURL)
    }

    func isRunning(rootPath: URL) -> Bool {
        runningRootPaths.contains(rootPath.standardizedFileURL)
    }
}

#endif
