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
    
    static func createWithDefaultValues(osType: VMOSType) -> VMConfigModel {
        switch osType {
        case .macOS:
            return VMConfigModel(
                type: osType,
                name: "Easy Virtual Machine (macOS)",
                remark: "",
                cpu: VMModelFieldCPU.default(),
                memory: VMModelFieldMemory.default(),
                graphicsDevices: [VMModelFieldGraphicDevice.default(osType: osType)],
                storageDevices: [VMModelFieldStorageDevice.default()],
                networkDevices: [VMModelFieldNetworkDevice.default()],
                pointingDevices: [VMModelFieldPointingDevice(type: .USBScreenCoordinatePointing)],
                audioDevices: [VMModelFieldAudioDevice.default()]
            )
        case .linux:
            return VMConfigModel(
                type: osType,
                name: "Easy Virtual Machine (Linux)",
                remark: "",
                cpu: VMModelFieldCPU.default(),
                memory: VMModelFieldMemory.default(),
                graphicsDevices: [VMModelFieldGraphicDevice.default(osType: osType)],
                storageDevices: [VMModelFieldStorageDevice.default()],
                networkDevices: [VMModelFieldNetworkDevice.default()],
                pointingDevices: [VMModelFieldPointingDevice(type: .USBScreenCoordinatePointing)],
                audioDevices: [VMModelFieldAudioDevice.default()]
            )
        }
    }
    
    
    func writeConfigToFile(path: URL) -> VMOSResultVoid {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            let data = try encoder.encode(self)
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


struct VMStateModel : Decodable, Encodable  {
    let imagePath: URL
    
    
    func writeStateToFile(path: URL) -> VMOSResultVoid {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            let data = try encoder.encode(self)
            guard let content = String(data: data, encoding: .utf8) else {
                return .failure("failed to parse to utf8")
            }
            try content.write(toFile: path.path(percentEncoded: false), atomically: true, encoding: .utf8)
            return .success
        } catch {
            return .failure("\(error)")
        }
    }
    
    func writeStateToFile(path: URL) async throws {
        return try await withCheckedThrowingContinuation({ continuation in
            let result = writeStateToFile(path: path)
            if case let .failure(error) = result {
                continuation.resume(throwing: VMOSError.regularFailure(error))
                return
            }
            continuation.resume(returning: ())
        })
    }
}

struct VMModel: Identifiable {
    let id = UUID()
    let rootPath: URL
    let state: VMStateModel
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
    var efiVariableStoreURL : URL {
        rootPath.appending(path: "NVRAM")
    }
    
    var stateURL: URL {
        Self.getStateURL(rootPath: rootPath)
    }
    static func getStateURL(rootPath: URL) -> URL {
        rootPath.appending(path: "state.json")
    }
    var configURL: URL {
        Self.getConfigURL(rootPath: rootPath)
    }

    static func getConfigURL(rootPath: URL) -> URL {
        rootPath.appending(path: "config.json")
    }
    
    var displayDiskInfo: String {
        config.storageDevices.map({$0.shortDescription}).joined(separator: " ")
    }
    
    var displayMemoryInfo: String {
        "\(config.memory)"
    }
    
    var displayAttributeInfo: String {
        var info = ""
        info += "Graphics : " + config.graphicsDevices.map({$0.description}).joined(separator: " , ")
        info += " | "
        info += "Network : " + config.networkDevices.map({$0.description}).joined(separator: " , ")
        info += " | "
        info += "Audio : " + config.audioDevices.map({$0.description}).joined(separator: " , ")
        return info
    }
    
    static func loadConfigFromFile(rootPath: URL) -> VMOSResult<VMModel, String> {
        do {
            // config is required
            let configPath = Self.getConfigURL(rootPath: rootPath)
            let configData = try Data(contentsOf: configPath)
            let config: VMConfigModel = try JSONDecoder().decode(VMConfigModel.self, from: configData)
            
            // state is optional
            var state = VMStateModel(imagePath: URL(filePath: ""))
            let statePath = Self.getStateURL(rootPath: rootPath)
            if let stateData = try? Data(contentsOf: statePath) {
                if let stateRead: VMStateModel = try? JSONDecoder().decode(VMStateModel.self, from: stateData) {
                    state = stateRead
                }
            }

            let model = VMModel(rootPath: rootPath, state: state, config: config)
            return .success(model)
        } catch {
            return .failure("\(error)")
        }
    }
    

}
