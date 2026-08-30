import Foundation
import Virtualization

/// Experimental proof for the macOS 27 Custom Virtio API's ability to drive
/// Linux virtio-input. The public API doesn't expose guest config-space writes,
/// so this device deliberately uses one static capability payload. It is off by
/// default and exists to turn that API limitation into a repeatable guest test.
@available(macOS 27.0, *)
final class VirtioInputProbeDevice: NSObject, @unchecked Sendable,
    VZCustomVirtioDeviceConfigurationDelegate,
    VZCustomVirtioDeviceDelegate
{
    private enum Constants {
        static let deviceID: UInt16 = 18
        static let queueCount: UInt16 = 2
        static let eventQueue: UInt16 = 0
        static let statusQueue: UInt16 = 1
        static let eventKey: UInt16 = 1
        static let eventSyn: UInt16 = 0
        static let synReport: UInt16 = 0
    }

    let deviceQueue = DispatchQueue(label: "com.everettjf.ezvm.prototype.virtio-input-probe")
    private weak var device: VZCustomVirtioDevice?
    private var pendingEvents: [Data] = []
    private var deliveredEventCount: UInt64 = 0

    func makeConfiguration() -> VZCustomVirtioDeviceConfiguration {
        let configuration = VZCustomVirtioDeviceConfiguration()
        configuration.deviceID = Constants.deviceID
        configuration.pciClassID = 0x09
        configuration.pciSubclassID = 0x80
        configuration.virtioQueueCount = Constants.queueCount

        // struct virtio_input_config: select, subsel, size, reserved[5],
        // union[128]. A static response cannot accurately answer every Linux
        // query. The probe advertises only KEY_ENTER in the shared bitmap. If
        // Linux accepts this compromise, event transport can still be tested.
        var data = Data(repeating: 0, count: 136)
        data[2] = 16
        data[8 + 3] = 1 << 4 // Linux KEY_ENTER (28).
        data.replaceSubrange(8 + 4..<8 + 8, with: [0xff, 0xff, 0xff, 0x7f])
        configuration.deviceSpecificConfiguration = VZVirtioDeviceSpecificConfiguration(
            configurationData: data
        )
        configuration.provider = VZCustomVirtioDeviceDelegateProvider(
            deviceQueue: deviceQueue,
            delegate: self
        )
        return configuration
    }

    func customVirtioConfiguration(
        _ deviceConfiguration: VZCustomVirtioDeviceConfiguration,
        didCreateDevice device: VZCustomVirtioDevice
    ) {
        self.device = device
        device.delegate = self
        print("[stage5] created static virtio-input probe")
    }

    func customVirtioDeviceDidAcceptDriverOk(_ device: VZCustomVirtioDevice) {
        print(
            "[stage5] virtio-input probe DRIVER_OK; "
                + "event=\(device.queue(at: Constants.eventQueue) != nil), "
                + "status=\(device.queue(at: Constants.statusQueue) != nil)"
        )
        drainEvents()
    }

    func customVirtioDevice(
        _ device: VZCustomVirtioDevice,
        didReceiveNotificationFor queue: VZVirtioQueue
    ) {
        if queue.queueIndex == Constants.eventQueue {
            drainEvents()
        } else if queue.queueIndex == Constants.statusQueue {
            while let element = queue.nextElement() {
                _ = element.readBuffers()
                element.returnToQueue()
            }
        }
    }

    func customVirtioDeviceWillReset(_ device: VZCustomVirtioDevice) {
        pendingEvents.removeAll()
    }

    func customVirtioDeviceWillStop(_ device: VZCustomVirtioDevice) {
        pendingEvents.removeAll()
    }

    func sendKey(code: UInt16, pressed: Bool) {
        deviceQueue.async { [weak self] in
            guard let self else { return }
            pendingEvents.append(Self.event(
                type: Constants.eventKey,
                code: code,
                value: pressed ? 1 : 0
            ))
            pendingEvents.append(Self.event(
                type: Constants.eventSyn,
                code: Constants.synReport,
                value: 0
            ))
            drainEvents()
        }
    }

    private func drainEvents() {
        guard let queue = device?.queue(at: Constants.eventQueue) else { return }
        while !pendingEvents.isEmpty, let element = queue.nextElement() {
            let event = pendingEvents.removeFirst()
            do {
                try element.write(event)
                element.returnToQueue()
                deliveredEventCount &+= 1
                print("[stage5] delivered virtio-input event \(deliveredEventCount)")
            } catch {
                element.returnToQueue()
                print("[stage5] failed to write virtio-input event: \(error.localizedDescription)")
            }
        }
    }

    private static func event(type: UInt16, code: UInt16, value: Int32) -> Data {
        var data = Data()
        withUnsafeBytes(of: type.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: code.littleEndian) { data.append(contentsOf: $0) }
        data.appendLittleEndian(UInt32(bitPattern: value))
        return data
    }
}
