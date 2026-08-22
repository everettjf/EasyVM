import Foundation
import Virtualization

#if arch(arm64)
struct VMModelFieldNetworkDevice: Codable, CustomStringConvertible {
    enum DeviceType: String, CaseIterable, Identifiable, Codable {
        case NAT, FileHandle

        var id: Self { self }
        static var userSelectableCases: [Self] { [.NAT] }
    }

    let type: DeviceType

    init(type: DeviceType) {
        self.type = type
    }

    private enum CodingKeys: String, CodingKey { case type }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let savedType = try container.decodeIfPresent(String.self, forKey: .type) ?? DeviceType.NAT.rawValue
        // Experimental builds could save bridged or vmnet-backed modes.
        // Existing machines fall back to ordinary NAT networking.
        type = DeviceType(rawValue: savedType) ?? .NAT
    }

    var description: String { type.rawValue }

    static func `default`() -> VMModelFieldNetworkDevice {
        VMModelFieldNetworkDevice(type: .NAT)
    }

    static func createConfigurations(_ models: [VMModelFieldNetworkDevice]) -> VMOSResult<[VZNetworkDeviceConfiguration], String> {
        var configurations: [VZNetworkDeviceConfiguration] = []
        for model in models {
            switch model.createConfiguration() {
            case .success(let configuration): configurations.append(configuration)
            case .failure(let error): return .failure(error)
            }
        }
        return .success(configurations)
    }

    var validationError: String? { nil }

    func createConfiguration() -> VMOSResult<VZNetworkDeviceConfiguration, String> {
        let device = VZVirtioNetworkDeviceConfiguration()
        switch type {
        case .NAT:
            device.attachment = VZNATNetworkDeviceAttachment()
        case .FileHandle:
            return .failure("Legacy FileHandle networking requires a live file descriptor and can no longer be configured from a saved VM.")
        }
        return .success(device)
    }
}
#endif
