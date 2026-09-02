//
//  AppDelegate.swift
//  EZVM
//
//  Created by everettjf on 2022/6/24.
//

import Foundation
import Cocoa
import SwiftUI
import CryptoKit


@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    private var releaseSmokeWindow: NSWindow?
    private var guiReadyAttempts = 0
    private var guiReadyEventMonitor: Any?
#if arch(arm64)
    private var headlessController: VMOSInternalVirtualMachineViewController?
    private var headlessState: VMRuntimeState?
    private var headlessTimer: Timer?
    private var headlessWindow: NSWindow?
    private var terminationSources: [DispatchSourceSignal] = []
    private var headlessStopRequested = false
    private var imageInstallStagingURL: URL?
    private var imageInstallTerminationSources: [DispatchSourceSignal] = []
#endif

    func applicationDidFinishLaunching(_ notification: Notification) {
#if arch(arm64)
        if let fixture = ReleaseFixtureCreationConfiguration.current {
            createReleaseFixture(fixture)
            return
        }
        if let install = PreinstalledImageInstallConfiguration.current {
            installPreinstalledImage(install)
            return
        }
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
        window.title = "EZVM Release Smoke Test"
        window.makeKeyAndOrderFront(nil)
        releaseSmokeWindow = window
#endif
    }

    private func scheduleGUIReadyProbe() {
        guard let markerPath = ProcessInfo.processInfo.environment["EZVM_GUI_READY_FILE"], !markerPath.isEmpty else { return }
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
                EZVMLog.error("The main SwiftUI window did not become visible for the GUI readiness probe.")
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
            EZVMLog.error("Could not write GUI readiness marker: \(error.localizedDescription)")
        }
    }

#if arch(arm64)
    private func createReleaseFixture(_ fixture: ReleaseFixtureCreationConfiguration) {
        NSApp.setActivationPolicy(.prohibited)
        for window in NSApp.windows { window.orderOut(nil) }
        Task {
            if !FileManager.default.fileExists(atPath: fixture.imageURL.path) {
                guard fixture.osType == .macOS else {
                    fixture.report("failed: installer image not found: \(fixture.imageURL.path)")
                    exit(66)
                }
                let download = await downloadLatestMacOSFixture(to: fixture.imageURL)
                if case let .failure(message) = download {
                    fixture.report("failed: \(message)")
                    exit(69)
                }
            }
            let result = await VMOSCreateFactory.getCreator(fixture.osType).create(model: fixture.model) { progress in
                switch progress {
                case .info(let message): print(message)
                case .error(let message): FileHandle.standardError.write(Data((message + "\n").utf8))
                case .progress(let fraction): print("fixture-progress \(Int(fraction * 100))%")
                }
                fflush(stdout)
            }
            switch result {
            case .success:
                if fixture.provisionsMacGuest {
                    let credential = VMGuestProvisioningCredential(
                        fullName: "EZVM Release Test",
                        username: "ezvmm9",
                        password: UUID().uuidString + "aA1!",
                        logsInAutomatically: false,
                        enablesRemoteLogin: false
                    )
                    if case let .failure(message) = VMGuestProvisioningCredentialStore.save(
                        credential,
                        vmRootPath: fixture.destinationURL
                    ) {
                        fixture.report("failed: \(message)")
                        exit(71)
                    }
                }
                fixture.report("created")
                exit(0)
            case .failure(let message):
                fixture.report("failed: \(message)")
                exit(70)
            }
        }
    }

    private func downloadLatestMacOSFixture(to destination: URL) async -> VMOSResultVoid {
        await withCheckedContinuation { continuation in
            VMOSDownloaderForMacOS().downloadLatest(toLocalPath: destination) { result in
                continuation.resume(returning: result)
            } downloadProgressHandler: { fraction in
                print("fixture-download-progress \(Int(fraction * 100))%")
                fflush(stdout)
            }
        }
    }

    private func installPreinstalledImage(_ install: PreinstalledImageInstallConfiguration) {
        NSApp.setActivationPolicy(.prohibited)
        for window in NSApp.windows { window.orderOut(nil) }
        installImageTerminationHandlers()
        Task {
            let result = await performPreinstalledImageInstall(install)
            imageInstallTerminationSources.forEach { $0.cancel() }
            imageInstallTerminationSources.removeAll()
            switch result {
            case .success:
                print("Installed EZVM machine: \(install.destinationURL.path)")
                fflush(stdout)
                exit(0)
            case .failure(let message):
                FileHandle.standardError.write(Data("EZVM image installation failed: \(message)\n".utf8))
                exit(70)
            }
        }
    }

    private func performPreinstalledImageInstall(_ install: PreinstalledImageInstallConfiguration) async -> VMOSResultVoid {
        let fileManager = FileManager.default
        let manifest: PreinstalledImageManifest
        do {
            manifest = try PreinstalledImageManifest.load(from: install.manifestURL)
        } catch {
            return .failure("Invalid preinstalled-image manifest: \(error.localizedDescription)")
        }
        guard fileManager.fileExists(atPath: install.imageURL.path) else {
            return .failure("Disk image not found: \(install.imageURL.path)")
        }
        guard install.destinationURL.pathExtension.lowercased() == "ezvm" else {
            return .failure("Destination must use the .ezvm extension.")
        }
        guard !fileManager.fileExists(atPath: install.destinationURL.path) else {
            return .failure("Destination already exists: \(install.destinationURL.path)")
        }
        guard let attributes = try? fileManager.attributesOfItem(atPath: install.imageURL.path),
              let imageSize = attributes[.size] as? NSNumber,
              imageSize.uint64Value == manifest.disk.virtualSize else {
            return .failure("The preinstalled disk image size does not match its manifest.")
        }
        do {
            guard try Self.sha256(of: install.imageURL) == manifest.disk.sha256.lowercased() else {
                return .failure("The preinstalled disk image SHA-256 does not match its manifest.")
            }
        } catch {
            return .failure("Could not verify the preinstalled disk image: \(error.localizedDescription)")
        }

        let stagingURL = install.destinationURL.deletingLastPathComponent()
            .appendingPathComponent(".\(install.destinationURL.lastPathComponent).install-\(install.stagingToken)", isDirectory: true)
        imageInstallStagingURL = stagingURL
        defer {
            try? fileManager.removeItem(at: stagingURL)
            imageInstallStagingURL = nil
        }
        let diskURL = stagingURL.appending(path: "Disk.img")
        do {
            try fileManager.createDirectory(at: install.destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.createDirectory(at: stagingURL, withIntermediateDirectories: false)
            try fileManager.copyItem(at: install.imageURL, to: diskURL)
        } catch {
            return .failure("Could not stage the disk image: \(error.localizedDescription)")
        }

        let defaults = VMConfigModel.createWithDefaultValues(osType: .linux)
        let resources = VMPreinstalledImageResourceRecommendation.recommended()
        let config = VMConfigModel(
            type: .linux,
            name: install.name ?? manifest.virtualMachine.name,
            remark: manifest.virtualMachine.remark ?? "Preinstalled \(manifest.product.name) \(manifest.product.version)",
            cpu: VMModelFieldCPU(count: resources.cpuCount),
            memory: VMModelFieldMemory(size: resources.memorySize),
            graphicsDevices: defaults.graphicsDevices,
            storageDevices: [VMModelFieldStorageDevice(
                type: .Block,
                size: imageSize.uint64Value,
                imagePath: diskURL.lastPathComponent,
                format: .raw
            )],
            networkDevices: defaults.networkDevices,
            pointingDevices: defaults.pointingDevices,
            audioDevices: defaults.audioDevices,
            directorySharingDevices: defaults.directorySharingDevices,
            linuxFeatures: .recommended
        )
        let model = VMModel(
            rootPath: stagingURL,
            state: VMStateModel(imagePath: diskURL),
            config: config
        )
        let result = await VMOSCreatorForLinux().create(model: model) { progress in
            switch progress {
            case .info(let message): print(message)
            case .error(let message): FileHandle.standardError.write(Data((message + "\n").utf8))
            case .progress: break
            }
        }
        guard case .success = result else {
            return result
        }
        if let thumbnailURL = install.thumbnailURL {
            guard let fileSize = try? thumbnailURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  fileSize <= 20 * 1024 * 1024,
                  let image = NSImage(contentsOf: thumbnailURL), image.isValid else {
                return .failure("The supplied thumbnail is not a valid image or exceeds 20 MB.")
            }
            let scale = min(1, 720 / max(image.size.width, 1))
            let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
            let thumbnail = NSImage(size: size)
            thumbnail.lockFocus()
            image.draw(in: NSRect(origin: .zero, size: size))
            thumbnail.unlockFocus()
            guard let cgImage = thumbnail.cgImage(forProposedRect: nil, context: nil, hints: nil),
                  let pngData = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:]) else {
                return .failure("The supplied thumbnail is not a valid image.")
            }
            do {
                try pngData.write(to: stagingURL.appending(path: "screenshot.png"), options: .atomic)
            } catch {
                return .failure("Could not install the supplied thumbnail: \(error.localizedDescription)")
            }
        }
        let committedState = VMStateModel(
            imagePath: install.destinationURL.appending(path: diskURL.lastPathComponent)
        )
        if case let .failure(error) = committedState.writeStateToFile(path: model.stateURL) {
            return .failure("Could not finalize the installed machine state: \(error)")
        }
        do {
            try fileManager.moveItem(at: stagingURL, to: install.destinationURL)
        } catch {
            return .failure("Could not commit the installed machine: \(error.localizedDescription)")
        }
        sharedAppConfigManager.addVMPath(url: install.destinationURL)
        return .success
    }

    private func installImageTerminationHandlers() {
        signal(SIGTERM, SIG_IGN)
        signal(SIGINT, SIG_IGN)
        for signalNumber in [SIGTERM, SIGINT] {
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler { [weak self] in
                guard let self else { return }
                if let stagingURL = self.imageInstallStagingURL { try? FileManager.default.removeItem(at: stagingURL) }
                exit(128 + signalNumber)
            }
            source.resume()
            imageInstallTerminationSources.append(source)
        }
    }

    nonisolated private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            // FileHandle bridges through Foundation on macOS. Drain each
            // autoreleased read buffer so importing a large sparse disk stays
            // constant-memory under system memory pressure.
            let reachedEnd = try autoreleasepool {
                let data = try handle.read(upToCount: 4 * 1024 * 1024) ?? Data()
                guard !data.isEmpty else { return true }
                hasher.update(data: data)
                return false
            }
            if reachedEnd { break }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func startHeadless(_ launch: HeadlessLaunchConfiguration) {
        // SwiftUI creates the Control Center scene before the app delegate is
        // told to enter headless mode. Its content is intentionally EmptyView
        // in this process, so leaving that scene visible produces a second,
        // blank "Control Center" window beside a windowed VM launch.
        for window in NSApp.windows { window.orderOut(nil) }
        if launch.showsWindow {
            NSApp.setActivationPolicy(.regular)
        } else {
            NSApp.setActivationPolicy(.prohibited)
        }
        let state = VMRuntimeState()
        let controller = VMOSInternalVirtualMachineViewController()
        controller.rootPath = launch.machineURL
        controller.runtimeState = state
        state.controller = controller
        headlessState = state
        headlessController = controller
        if launch.showsWindow {
            let window = NSWindow(contentViewController: controller)
            window.setContentSize(NSSize(width: 1280, height: 720))
            if let primaryScreen = NSScreen.screens.first(where: { $0.frame.contains(NSPoint.zero) }) {
                let visible = primaryScreen.visibleFrame
                window.setFrameOrigin(NSPoint(
                    x: visible.midX - window.frame.width / 2,
                    y: visible.midY - window.frame.height / 2
                ))
            } else {
                window.center()
            }
            window.title = launch.machineURL.deletingPathExtension().lastPathComponent
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            headlessWindow = window
            // Loading the controller can enqueue its initial focus request
            // before the view is attached to this window. Retry after the
            // window is key so VZVirtualMachineView can route HID events.
            DispatchQueue.main.async {
                controller.focusVirtualMachineDisplay()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                guard window.isKeyWindow else { return }
                controller.focusVirtualMachineDisplay()
            }
        }
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
        // The VM controller owns the bounded graceful-shutdown fallback.
        // Scheduling a second force-stop here at the same 20-second deadline
        // races VZVirtualMachine.stop() against itself and turns a successful
        // stopping transition into an invalid stopping -> stopping failure.
        headlessState?.requestStop()
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
            EZVMLog.error("Could not write headless state: \(error.localizedDescription)")
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
struct ReleaseFixtureCreationConfiguration {
    let osType: VMOSType
    let imageURL: URL
    let destinationURL: URL
    let resultURL: URL
    let provisionsMacGuest: Bool

    static var current: ReleaseFixtureCreationConfiguration? {
        let environment = ProcessInfo.processInfo.environment
        guard let osValue = environment["EZVM_RELEASE_CREATE_OS"],
              let osType = VMOSType(rawValue: osValue),
              let imagePath = environment["EZVM_RELEASE_CREATE_IMAGE"], !imagePath.isEmpty,
              let destinationPath = environment["EZVM_RELEASE_CREATE_VM"], !destinationPath.isEmpty,
              let resultPath = environment["EZVM_RELEASE_CREATE_RESULT"], !resultPath.isEmpty else {
            return nil
        }
        return ReleaseFixtureCreationConfiguration(
            osType: osType,
            imageURL: URL(filePath: imagePath).standardizedFileURL,
            destinationURL: URL(filePath: destinationPath, directoryHint: .isDirectory).standardizedFileURL,
            resultURL: URL(filePath: resultPath).standardizedFileURL,
            provisionsMacGuest: osType == .macOS && environment["EZVM_RELEASE_PROVISION_MACOS"] == "1"
        )
    }

    var model: VMModel {
        let defaults = VMConfigModel.createWithDefaultValues(osType: osType)
        let storageDevices: [VMModelFieldStorageDevice]
        switch osType {
        case .linux:
            storageDevices = defaults.storageDevices + [
                VMModelFieldStorageDevice(type: .USB, size: 0, imagePath: imageURL.path)
            ]
        case .macOS:
            storageDevices = defaults.storageDevices
        }
        let config = VMConfigModel(
            type: osType,
            name: osType == .linux ? "Ubuntu Release Fixture" : "macOS Release Fixture",
            remark: "Disposable M9 release fixture",
            cpu: defaults.cpu,
            memory: defaults.memory,
            graphicsDevices: defaults.graphicsDevices,
            storageDevices: storageDevices,
            networkDevices: defaults.networkDevices,
            pointingDevices: defaults.pointingDevices,
            audioDevices: defaults.audioDevices,
            directorySharingDevices: defaults.directorySharingDevices,
            linuxFeatures: defaults.linuxFeatures
        )
        return VMModel(
            rootPath: destinationURL,
            state: VMStateModel(imagePath: imageURL),
            config: config
        )
    }

    func report(_ value: String) {
        do {
            try (value + "\n").write(to: resultURL, atomically: true, encoding: .utf8)
        } catch {
            FileHandle.standardError.write(Data("Could not write fixture result: \(error.localizedDescription)\n".utf8))
        }
    }
}

struct PreinstalledImageInstallConfiguration {
    let manifestURL: URL
    let imageURL: URL
    let destinationURL: URL
    let name: String?
    let thumbnailURL: URL?
    let stagingToken: String
    let configuration: VMConfigModel?

    static var current: PreinstalledImageInstallConfiguration? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let marker = arguments.firstIndex(of: "--ezvm-install-preinstalled-image"), marker + 1 < arguments.count,
              let imageMarker = arguments.firstIndex(of: "--image"), imageMarker + 1 < arguments.count,
              let destinationMarker = arguments.firstIndex(of: "--destination"), destinationMarker + 1 < arguments.count,
              let stagingMarker = arguments.firstIndex(of: "--staging-token"), stagingMarker + 1 < arguments.count,
              UUID(uuidString: arguments[stagingMarker + 1]) != nil else {
            return nil
        }
        let nameMarker = arguments.firstIndex(of: "--name")
        let thumbnailMarker = arguments.firstIndex(of: "--thumbnail")
        return PreinstalledImageInstallConfiguration(
            manifestURL: URL(fileURLWithPath: arguments[marker + 1]).standardizedFileURL,
            imageURL: URL(fileURLWithPath: arguments[imageMarker + 1]).standardizedFileURL,
            destinationURL: URL(fileURLWithPath: arguments[destinationMarker + 1]).standardizedFileURL,
            name: nameMarker.flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil },
            thumbnailURL: thumbnailMarker.flatMap {
                $0 + 1 < arguments.count ? URL(fileURLWithPath: arguments[$0 + 1]).standardizedFileURL : nil
            },
            stagingToken: arguments[stagingMarker + 1],
            configuration: nil
        )
    }
}

struct PreinstalledImageManifest: Decodable {
    static let kind = "io.github.everettjf.ezvm.preinstalled-image"
    struct Product: Decodable { let id: String; let name: String; let version: String }
    struct Disk: Decodable { let format: String; let virtualSize: UInt64; let sha256: String }
    struct VirtualMachine: Decodable { let name: String; let remark: String? }
    struct Archive: Decodable {
        struct Part: Decodable { let name: String; let size: Int64; let sha256: String }
        let compression: String
        let compressedSize: Int64
        let sha256: String
        let parts: [Part]
    }
    struct Thumbnail: Decodable { let name: String; let mediaType: String; let size: Int64; let sha256: String }
    struct Release: Decodable { let repository: String; let tag: String }

    let schemaVersion: Int
    let kind: String
    let architecture: String
    let minimumEZVMVersion: String
    let product: Product
    let disk: Disk
    let virtualMachine: VirtualMachine
    let archive: Archive?
    let thumbnail: Thumbnail?
    let release: Release?

    static func load(from url: URL) throws -> Self {
        let value = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        guard value.schemaVersion == 1, value.kind == kind, value.architecture == "arm64",
              value.disk.format == "raw", value.disk.virtualSize >= VMModelFieldStorageDevice.minDiskSize(),
              value.disk.sha256.count == 64, value.disk.sha256.allSatisfy({ $0.isHexDigit }),
              !value.product.id.isEmpty, !value.product.name.isEmpty, !value.product.version.isEmpty,
              !value.virtualMachine.name.isEmpty else {
            throw ManifestError.invalid
        }
        let runningVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        guard runningVersion.compare(value.minimumEZVMVersion, options: .numeric) != .orderedAscending else {
            throw ManifestError.version(required: value.minimumEZVMVersion, actual: runningVersion)
        }
        return value
    }

    enum ManifestError: LocalizedError {
        case invalid
        case version(required: String, actual: String)
        var errorDescription: String? {
            switch self {
            case .invalid: "The manifest identity, schema, architecture, disk, or product metadata is invalid."
            case .version(let required, let actual): "This image requires EZVM \(required) or newer; this app is \(actual)."
            }
        }
    }
}

@MainActor
struct VMPreinstalledImageInstaller {
    static func install(
        _ install: PreinstalledImageInstallConfiguration,
        progress: @escaping (VMOSCreatorProgressInfo) -> Void = { _ in }
    ) async -> VMOSResultVoid {
        let fileManager = FileManager.default
        let manifest: PreinstalledImageManifest
        do {
            manifest = try PreinstalledImageManifest.load(from: install.manifestURL)
        } catch {
            return .failure("Invalid preinstalled-image manifest: \(error.localizedDescription)")
        }
        guard fileManager.fileExists(atPath: install.imageURL.path) else {
            return .failure("Disk image not found: \(install.imageURL.path)")
        }
        guard install.destinationURL.pathExtension.lowercased() == "ezvm" else {
            return .failure("Destination must use the .ezvm extension.")
        }
        guard !fileManager.fileExists(atPath: install.destinationURL.path) else {
            return .failure("Destination already exists: \(install.destinationURL.path)")
        }
        guard let attributes = try? fileManager.attributesOfItem(atPath: install.imageURL.path),
              let imageSize = attributes[.size] as? NSNumber,
              imageSize.uint64Value == manifest.disk.virtualSize else {
            return .failure("The preinstalled disk image size does not match its manifest.")
        }
        do {
            guard try sha256(of: install.imageURL) == manifest.disk.sha256.lowercased() else {
                return .failure("The preinstalled disk image SHA-256 does not match its manifest.")
            }
        } catch {
            return .failure("Could not verify the preinstalled disk image: \(error.localizedDescription)")
        }

        let stagingURL = install.destinationURL.deletingLastPathComponent()
            .appendingPathComponent(".\(install.destinationURL.lastPathComponent).install-\(install.stagingToken)", isDirectory: true)
        defer { try? fileManager.removeItem(at: stagingURL) }
        let diskURL = stagingURL.appending(path: "Disk.img")
        do {
            try fileManager.createDirectory(at: install.destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.createDirectory(at: stagingURL, withIntermediateDirectories: false)
            try fileManager.copyItem(at: install.imageURL, to: diskURL)
        } catch {
            return .failure("Could not stage the disk image: \(error.localizedDescription)")
        }

        let defaults = install.configuration ?? VMConfigModel.createWithDefaultValues(osType: .linux)
        let resources = VMPreinstalledImageResourceRecommendation.recommended()
        let config = VMConfigModel(
            type: .linux,
            name: install.name ?? defaults.name.ifEmpty(manifest.virtualMachine.name),
            remark: defaults.remark.ifEmpty(manifest.virtualMachine.remark ?? "Preinstalled \(manifest.product.name) \(manifest.product.version)"),
            cpu: install.configuration?.cpu ?? VMModelFieldCPU(count: resources.cpuCount),
            memory: install.configuration?.memory ?? VMModelFieldMemory(size: resources.memorySize),
            graphicsDevices: defaults.graphicsDevices,
            storageDevices: [VMModelFieldStorageDevice(type: .Block, size: imageSize.uint64Value, imagePath: diskURL.lastPathComponent, format: .raw)],
            networkDevices: defaults.networkDevices,
            pointingDevices: defaults.pointingDevices,
            audioDevices: defaults.audioDevices,
            directorySharingDevices: defaults.directorySharingDevices,
            linuxFeatures: defaults.linuxFeatures ?? .recommended
        )
        let model = VMModel(rootPath: stagingURL, state: VMStateModel(imagePath: diskURL), config: config)
        let result = await VMOSCreatorForLinux().create(model: model, progress: progress)
        guard case .success = result else { return result }

        if let thumbnailURL = install.thumbnailURL {
            guard let fileSize = try? thumbnailURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  fileSize <= 20 * 1024 * 1024,
                  let image = NSImage(contentsOf: thumbnailURL), image.isValid else {
                return .failure("The supplied thumbnail is not a valid image or exceeds 20 MB.")
            }
            let scale = min(1, 720 / max(image.size.width, 1))
            let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
            let thumbnail = NSImage(size: size)
            thumbnail.lockFocus()
            image.draw(in: NSRect(origin: .zero, size: size))
            thumbnail.unlockFocus()
            guard let cgImage = thumbnail.cgImage(forProposedRect: nil, context: nil, hints: nil),
                  let pngData = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:]) else {
                return .failure("The supplied thumbnail is not a valid image.")
            }
            do { try pngData.write(to: stagingURL.appending(path: "screenshot.png"), options: .atomic) }
            catch { return .failure("Could not install the supplied thumbnail: \(error.localizedDescription)") }
        }
        let committedState = VMStateModel(imagePath: install.destinationURL.appending(path: diskURL.lastPathComponent))
        if case let .failure(error) = committedState.writeStateToFile(path: model.stateURL) {
            return .failure("Could not finalize the installed machine state: \(error)")
        }
        do { try fileManager.moveItem(at: stagingURL, to: install.destinationURL) }
        catch { return .failure("Could not commit the installed machine: \(error.localizedDescription)") }
        sharedAppConfigManager.addVMPath(url: install.destinationURL)
        return .success
    }

    nonisolated static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let data = try handle.read(upToCount: 4 * 1024 * 1024) ?? Data()
            guard !data.isEmpty else { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

private extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}

struct HeadlessLaunchConfiguration {
    let machineURL: URL
    let stateURL: URL
    let launchToken: String
    let showsWindow: Bool

    static var current: HeadlessLaunchConfiguration? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let marker = arguments.firstIndex(of: "--ezvm-headless"), marker + 1 < arguments.count,
              let stateMarker = arguments.firstIndex(of: "--state-file"), stateMarker + 1 < arguments.count,
              let tokenMarker = arguments.firstIndex(of: "--launch-token"), tokenMarker + 1 < arguments.count,
              UUID(uuidString: arguments[tokenMarker + 1]) != nil else { return nil }
        return HeadlessLaunchConfiguration(
            machineURL: URL(fileURLWithPath: arguments[marker + 1]).standardizedFileURL,
            stateURL: URL(fileURLWithPath: arguments[stateMarker + 1]).standardizedFileURL,
            launchToken: arguments[tokenMarker + 1],
            showsWindow: arguments.contains("--ezvm-show-window")
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
