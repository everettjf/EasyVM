import AppKit
import Foundation
import Metal
import QuartzCore
@preconcurrency import Virtualization

@available(macOS 27.0, *)
@MainActor
final class PrototypeApp: NSObject, NSApplicationDelegate, VZVirtualMachineDelegate {
    private var window: NSWindow!
    private var imageView: NSImageView!
    private var virtualMachine: VZVirtualMachine?
    private var gpuDevice: VirtioGPUDevice?
    private var renderer: VirGLRenderer?
    private var metalLayer: CAMetalLayer!
    private var zeroCopyFrameCount = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let arguments = try Arguments.parse(CommandLine.arguments)
            createWindow(width: Int(arguments.width), height: Int(arguments.height))
            try start(arguments: arguments)
        } catch {
            fputs("error: \(error)\n", stderr)
            NSApp.terminate(nil)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    nonisolated func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        print("VM stopped")
        Task { @MainActor in NSApp.terminate(nil) }
    }

    nonisolated func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: any Error) {
        fputs("VM stopped with error: \(error)\n", stderr)
        Task { @MainActor in NSApp.terminate(nil) }
    }

    private func createWindow(width: Int, height: Int) {
        imageView = NSImageView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        metalLayer = CAMetalLayer()
        metalLayer.device = MTLCreateSystemDefaultDevice()
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = false
        metalLayer.backgroundColor = NSColor.black.cgColor
        imageView.layer = metalLayer

        window = NSWindow(
            contentRect: imageView.bounds,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "VZ Custom Virtio GPU Prototype"
        window.contentView = imageView
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    private func start(arguments: Arguments) throws {
        let renderer = try VirGLRenderer(libraryURL: arguments.virglRendererURL)
        self.renderer = renderer
        let configuration = VZVirtualMachineConfiguration()
        configuration.cpuCount = arguments.cpuCount
        configuration.memorySize = arguments.memorySize

        let platform = VZGenericPlatformConfiguration()
        configuration.platform = platform

        if let kernelURL = arguments.kernelURL, let initrdURL = arguments.initrdURL {
            let bootLoader = VZLinuxBootLoader(kernelURL: kernelURL)
            bootLoader.initialRamdiskURL = initrdURL
            bootLoader.commandLine = arguments.kernelCommandLine
            configuration.bootLoader = bootLoader
            print("[stage3] direct Linux boot enabled: \(arguments.kernelCommandLine)")
        } else {
            let bootLoader = VZEFIBootLoader()
            bootLoader.variableStore = VZEFIVariableStore(url: arguments.nvramURL)
            configuration.bootLoader = bootLoader
        }

        let attachment = try VZDiskImageStorageDeviceAttachment(
            url: arguments.diskURL,
            readOnly: false
        )
        configuration.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: attachment)]
        configuration.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        configuration.networkDevices = [Self.natNetwork()]

        let gpuDevice = VirtioGPUDevice(
            width: arguments.width,
            height: arguments.height,
            renderer: renderer,
            onZeroCopyFrame: { [weak self] resourceID in
                self?.presentZeroCopy(resourceID: resourceID)
            }
        ) {
            [weak self] frame in
            self?.imageView.image = NSImage(cgImage: frame, size: .zero)
        }
        self.gpuDevice = gpuDevice
        configuration.customVirtioDevices = [gpuDevice.makeConfiguration()]

        print("[stage1] validating standard custom virtio-gpu configuration…")
        try configuration.validate()
        print("[stage1] configuration validation succeeded")

        let virtualMachine = VZVirtualMachine(configuration: configuration)
        virtualMachine.delegate = self
        self.virtualMachine = virtualMachine
        virtualMachine.start { result in
            switch result {
            case .success:
                print("VM started; waiting for Linux virtio-gpu driver")
            case let .failure(error):
                fputs("VM start failed: \(error)\n", stderr)
            }
        }
    }

    private func presentZeroCopy(resourceID: UInt32) {
        guard let renderer, let metalLayer,
              let device = metalLayer.device else { return }
        _ = device
        let scale = window.backingScaleFactor
        let size = imageView.bounds.size
        metalLayer.frame = imageView.bounds
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = CGSize(
            width: max(1, size.width * scale),
            height: max(1, size.height * scale)
        )
        guard let drawable = metalLayer.nextDrawable() else { return }
        let width = UInt32(drawable.texture.width)
        let height = UInt32(drawable.texture.height)
        guard renderer.present(
            resourceID: resourceID,
            into: drawable.texture,
            width: width,
            height: height
        ) else {
            fputs("[stage4] zero-copy present failed for resource \(resourceID)\n", stderr)
            return
        }
        drawable.present()
        zeroCopyFrameCount += 1
        if zeroCopyFrameCount == 1 || zeroCopyFrameCount.isMultiple(of: 300) {
            print("[stage4] zero-copy Metal frame \(zeroCopyFrameCount) presented")
        }
    }

    private static func natNetwork() -> VZVirtioNetworkDeviceConfiguration {
        let network = VZVirtioNetworkDeviceConfiguration()
        network.attachment = VZNATNetworkDeviceAttachment()
        network.macAddress = VZMACAddress.randomLocallyAdministered()
        return network
    }
}

@available(macOS 27.0, *)
struct Arguments {
    let diskURL: URL
    let nvramURL: URL
    let width: UInt32
    let height: UInt32
    let cpuCount: Int
    let memorySize: UInt64
    let virglRendererURL: URL
    let kernelURL: URL?
    let initrdURL: URL?
    let kernelCommandLine: String

    static func parse(_ values: [String]) throws -> Arguments {
        guard values.count >= 3 else { throw ArgumentError.usage }
        let defaultRendererPath = "/Applications/Try Omarchy.app/Contents/Resources/runtime/lib/libvirglrenderer.1.dylib"
        let rendererPath = ProcessInfo.processInfo.environment["VIRGL_RENDERER_PATH"]
            ?? defaultRendererPath
        let environment = ProcessInfo.processInfo.environment
        return Arguments(
            diskURL: URL(fileURLWithPath: values[1]),
            nvramURL: URL(fileURLWithPath: values[2]),
            width: 1280,
            height: 720,
            cpuCount: min(6, VZVirtualMachineConfiguration.maximumAllowedCPUCount),
            memorySize: 6 * 1024 * 1024 * 1024,
            virglRendererURL: URL(fileURLWithPath: rendererPath),
            kernelURL: environment["VZ_LINUX_KERNEL"].map(URL.init(fileURLWithPath:)),
            initrdURL: environment["VZ_LINUX_INITRD"].map(URL.init(fileURLWithPath:)),
            kernelCommandLine: environment["VZ_LINUX_COMMAND_LINE"] ?? ""
        )
    }

    enum ArgumentError: Error, CustomStringConvertible {
        case usage
        var description: String {
            "usage: vz-virtio-gpu-prototype <writable-disk.img> <writable-nvram>"
        }
    }
}

public func runVZVirtioGPUPrototype() {
    if #available(macOS 27.0, *) {
        MainActor.assumeIsolated {
            let application = NSApplication.shared
            let delegate = PrototypeApp()
            application.delegate = delegate
            application.setActivationPolicy(.regular)
            application.activate(ignoringOtherApps: true)
            application.run()
        }
    } else {
        fputs("This experiment requires macOS 27 or later.\n", stderr)
        exit(1)
    }
}
