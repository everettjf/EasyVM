//
//  AppDelegate.swift
//  EasyVM
//
//  Created by everettjf on 2022/6/24.
//

import Foundation
import Cocoa
import SwiftUI


@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    private var releaseSmokeWindow: NSWindow?
#if arch(arm64)
    private var headlessController: VMOSInternalVirtualMachineViewController?
    private var headlessState: VMRuntimeState?
    private var headlessTimer: Timer?
    private var terminationSources: [DispatchSourceSignal] = []
    private var headlessStopRequested = false
#endif

    func applicationDidFinishLaunching(_ notification: Notification) {
#if arch(arm64)
        if let launch = HeadlessLaunchConfiguration.current {
            startHeadless(launch)
            return
        }
        guard let smokeTest = VMReleaseSmokeTest.configuration() else { return }
        let controller = NSHostingController(
            rootView: VMOSMainVirtualMachineView(rootPath: smokeTest.vmRootPath, recoveryMode: false)
        )
        let window = NSWindow(contentViewController: controller)
        window.setContentSize(NSSize(width: 1024, height: 768))
        window.center()
        window.title = "EasyVM Release Smoke Test"
        window.makeKeyAndOrderFront(nil)
        releaseSmokeWindow = window
#endif
    }

#if arch(arm64)
    private func startHeadless(_ launch: HeadlessLaunchConfiguration) {
        NSApp.setActivationPolicy(.prohibited)
        for window in NSApp.windows { window.orderOut(nil) }
        let state = VMRuntimeState()
        let controller = VMOSInternalVirtualMachineViewController()
        controller.rootPath = launch.machineURL
        controller.runtimeState = state
        state.controller = controller
        headlessState = state
        headlessController = controller
        writeHeadlessState(launch, phase: "preparing", message: nil)
        _ = controller.view
        headlessTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.observeHeadless(launch) }
        }
        installTerminationHandlers(launch)
    }

    private func observeHeadless(_ launch: HeadlessLaunchConfiguration) {
        guard let phase = headlessState?.phase else { return }
        switch phase {
        case .failed(let message):
            writeHeadlessState(launch, phase: "failed", message: message)
            finishHeadless(exitCode: 70)
        case .stopped:
            writeHeadlessState(launch, phase: "stopped", message: nil)
            finishHeadless(exitCode: 0)
        default:
            writeHeadlessState(launch, phase: phase.title.lowercased(), message: nil)
        }
    }

    private func installTerminationHandlers(_ launch: HeadlessLaunchConfiguration) {
        signal(SIGTERM, SIG_IGN)
        signal(SIGINT, SIG_IGN)
        for signalNumber in [SIGTERM, SIGINT] {
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler { [weak self] in self?.requestHeadlessStop(launch) }
            source.resume()
            terminationSources.append(source)
        }
    }

    private func requestHeadlessStop(_ launch: HeadlessLaunchConfiguration) {
        guard !headlessStopRequested else { return }
        headlessStopRequested = true
        writeHeadlessState(launch, phase: "stopping", message: nil)
        headlessState?.requestStop()
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            guard let self, self.headlessState?.phase != .stopped else { return }
            self.headlessState?.forceStop()
        }
    }

    private func writeHeadlessState(_ launch: HeadlessLaunchConfiguration, phase: String, message: String?) {
        let value = HeadlessRuntimeRecord(schemaVersion: 1, pid: getpid(), machinePath: launch.machineURL.path,
                                          phase: phase, message: message, updatedAt: Date())
        guard let data = try? JSONEncoder().encode(value) else { return }
        do {
            try FileManager.default.createDirectory(at: launch.stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: launch.stateURL, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: launch.stateURL.path)
        } catch {
            EasyVMLog.error("Could not write headless state: \(error.localizedDescription)")
        }
    }

    private func finishHeadless(exitCode: Int32) {
        headlessTimer?.invalidate()
        headlessTimer = nil
        terminationSources.forEach { $0.cancel() }
        terminationSources.removeAll()
        fflush(stdout)
        exit(exitCode)
    }
#endif
    
    
//    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
//        true
//    }
}

#if arch(arm64)
struct HeadlessLaunchConfiguration {
    let machineURL: URL
    let stateURL: URL

    static var current: HeadlessLaunchConfiguration? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let marker = arguments.firstIndex(of: "--easyvm-headless"), marker + 1 < arguments.count,
              let stateMarker = arguments.firstIndex(of: "--state-file"), stateMarker + 1 < arguments.count else { return nil }
        return HeadlessLaunchConfiguration(
            machineURL: URL(fileURLWithPath: arguments[marker + 1]).standardizedFileURL,
            stateURL: URL(fileURLWithPath: arguments[stateMarker + 1]).standardizedFileURL
        )
    }
}

struct HeadlessRuntimeRecord: Codable {
    let schemaVersion: Int
    let pid: Int32
    let machinePath: String
    let phase: String
    let message: String?
    let updatedAt: Date
}
#endif
