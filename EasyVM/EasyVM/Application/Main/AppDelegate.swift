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
    private var guiReadyAttempts = 0
    private var guiReadyEventMonitor: Any?
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
        if VMReleaseSmokeTest.configuration() == nil {
            scheduleGUIReadyProbe()
            return
        }
        guard let smokeTest = VMReleaseSmokeTest.configuration() else { return }
        VMReleaseSmokeTest.reportProcessID(configuration: smokeTest)
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

    private func scheduleGUIReadyProbe() {
        guard let markerPath = ProcessInfo.processInfo.environment["EASYVM_GUI_READY_FILE"], !markerPath.isEmpty else { return }
        guiReadyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .applicationDefined) { [weak self] event in
            guard event.subtype.rawValue == 0x4556 else { return event }
            self?.writeGUIReadyMarker(markerPath: markerPath)
            return event
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.writeGUIReadyWhenVisible(markerPath: markerPath)
        }
    }

    private func writeGUIReadyWhenVisible(markerPath: String) {
        let visibleWindow = NSApp.windows.first { window in
            window.isVisible && window.contentViewController != nil && window.frame.width >= 800 && window.frame.height >= 600
        }
        guard let visibleWindow else {
            guiReadyAttempts += 1
            guard guiReadyAttempts < 100 else {
                EasyVMLog.error("The main SwiftUI window did not become visible for the GUI readiness probe.")
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.writeGUIReadyWhenVisible(markerPath: markerPath)
            }
            return
        }
        visibleWindow.makeKeyAndOrderFront(nil)
        let event = NSEvent.otherEvent(
            with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: visibleWindow.windowNumber, context: nil, subtype: .init(0x4556), data1: 0, data2: 0
        )
        guard let event else { return }
        NSApp.postEvent(event, atStart: false)
    }

    private func writeGUIReadyMarker(markerPath: String) {
        guard let visibleWindow = NSApp.windows.first(where: {
            $0.isVisible && $0.contentViewController != nil && $0.frame.width >= 800 && $0.frame.height >= 600
        }) else { return }
        let record: [String: Any] = [
            "schemaVersion": 1,
            "pid": getpid(),
            "eventLoopResponsive": true,
            "windowVisible": visibleWindow.isVisible,
            "windowWidth": Int(visibleWindow.frame.width),
            "windowHeight": Int(visibleWindow.frame.height),
            "bundleIdentifier": Bundle.main.bundleIdentifier ?? "",
        ]
        do {
            let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
            try data.write(to: URL(fileURLWithPath: markerPath), options: .atomic)
            if let guiReadyEventMonitor {
                NSEvent.removeMonitor(guiReadyEventMonitor)
                self.guiReadyEventMonitor = nil
            }
        } catch {
            EasyVMLog.error("Could not write GUI readiness marker: \(error.localizedDescription)")
        }
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
        let value = HeadlessRuntimeRecord(schemaVersion: 2, pid: getpid(), machinePath: launch.machineURL.path,
                                          phase: phase, message: message, updatedAt: Date(), launchToken: launch.launchToken)
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
    let launchToken: String

    static var current: HeadlessLaunchConfiguration? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let marker = arguments.firstIndex(of: "--easyvm-headless"), marker + 1 < arguments.count,
              let stateMarker = arguments.firstIndex(of: "--state-file"), stateMarker + 1 < arguments.count,
              let tokenMarker = arguments.firstIndex(of: "--launch-token"), tokenMarker + 1 < arguments.count,
              UUID(uuidString: arguments[tokenMarker + 1]) != nil else { return nil }
        return HeadlessLaunchConfiguration(
            machineURL: URL(fileURLWithPath: arguments[marker + 1]).standardizedFileURL,
            stateURL: URL(fileURLWithPath: arguments[stateMarker + 1]).standardizedFileURL,
            launchToken: arguments[tokenMarker + 1]
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
    let launchToken: String
}
#endif
