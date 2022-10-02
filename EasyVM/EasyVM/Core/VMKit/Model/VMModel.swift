//
//  VMModel.swift
//  EasyVM
//
//  Created by everettjf on 2022/8/6.
//

import Foundation
import SwiftUI

struct VMConfigModel : Decodable, Encodable {
    let type: VMOSType
    let name: String
    let remark: String
    
    let cpu: VMModelFieldCPU
    let memory: VMModelFieldMemory
    let graphicsDevices: [VMModelFieldGraphicDevice]
    let storageDevices: [VMModelFieldStorageDevice]
    let networkDevices: [VMModelFieldNetworkDevice]
    let pointingDevices: [VMModelFieldPointingDevice]
    let audioDevices: [VMModelFieldAudioDevice]
    
    static func create(osType: VMOSType, name: String, remark: String) -> VMConfigModel {
        return VMConfigModel(type: osType, name: name, remark: remark, cpu: VMModelFieldCPU.default(), memory: VMModelFieldMemory.default(), graphicsDevices: [VMModelFieldGraphicDevice.default()], storageDevices: [VMModelFieldStorageDevice.default()], networkDevices: [VMModelFieldNetworkDevice.default()], pointingDevices: [VMModelFieldPointingDevice(type: .USBScreenCoordinatePointing)], audioDevices: [VMModelFieldAudioDevice.default()])
    }
}


struct VMModel: Identifiable {
    let id = UUID()
    let rootPath: URL
    let imagePath: URL
    let config: VMConfigModel
    
    func getRootPath() -> URL {
        return rootPath
    }
    
    var auxiliaryStorageURL: URL {
        rootPath.appending(path: "AuxiliaryStorage")
    }
    var machineIdentifierURL: URL {
        rootPath.appending(path: "MachineIdentifier")
    }
    var hardwareModelURL: URL {
        rootPath.appending(path: "HardwareModel")
    }
    var diskImageURL: URL {
        rootPath.appending(path: "diskImagePath")
    }
//    var restoreImageURL: URL {
//        if config.type == .macOS {
//            return rootPath.appending(path: "RestoreImage.ipsw")
//        } else {
//            return rootPath.appending(path: "RestoreImage.iso")
//        }
//    }
    var configURL: URL {
        rootPath.appending(path: "config.json")
    }
    
    var displayDiskInfo: String {
        config.storageDevices.map({$0.shortDescription}).joined(separator: " ")
    }
    
    static func loadConfigFromFile(path: URL) -> VMOSResult<VMModel, String> {
        do {
            let data = try Data(contentsOf: path)
            let config: VMConfigModel = try JSONDecoder().decode(VMConfigModel.self, from: data)
            let model = VMModel(rootPath: path, imagePath: URL(filePath: ""), config: config)
            return .success(model)
        } catch {
            return .failure("\(error)")
        }
    }
    
    func writeConfigToFile(path: URL) -> VMOSResultVoid {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            let data = try encoder.encode(self.config)
            guard let content = String(data: data, encoding: .utf8) else {
                return .failure("failed to parse to utf8")
            }
            try content.write(toFile: path.path(percentEncoded: false), atomically: true, encoding: .utf8)
            return .success
        } catch {
            return .failure("\(error)")
        }
    }
    
    func writeConfigToFile(path: URL) async throws {
        return try await withCheckedThrowingContinuation({ continuation in
            let result = writeConfigToFile(path: path)
            if case let .failure(error) = result {
                continuation.resume(throwing: VMOSError.regularFailure(error))
                return
            }
            continuation.resume(returning: ())
        })
    }

}
