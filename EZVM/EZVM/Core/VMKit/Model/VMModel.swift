//
//  VMModel.swift
//  EZVM
//
//  Created by everettjf on 2022/8/6.
//

import Foundation
import SwiftUI

#if arch(arm64)
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
    let directorySharingDevices: [VMModelFieldDirectorySharingDevice]
    var linuxFeatures: VMLinuxFeatureConfiguration? = nil
    
    static func createWithDefaultValues(osType: VMOSType) -> VMConfigModel {
        switch osType {
        case .macOS:
            return VMConfigModel(
                type: osType,
                name: "EZVM Machine (macOS)",
                remark: "",
                cpu: VMModelFieldCPU.default(),
                memory: VMModelFieldMemory.default(),
                graphicsDevices: [VMModelFieldGraphicDevice.default(osType: osType)],
                storageDevices: [VMModelFieldStorageDevice.default()],
                networkDevices: [VMModelFieldNetworkDevice.default()],
                pointingDevices: [VMModelFieldPointingDevice(type: .USBScreenCoordinatePointing)],
                audioDevices: [VMModelFieldAudioDevice.default()],
                directorySharingDevices: [],
                linuxFeatures: nil
            )
        case .linux:
            return VMConfigModel(
                type: osType,
                name: "EZVM Machine (Linux)",
                remark: "",
                cpu: VMModelFieldCPU.default(),
                memory: VMModelFieldMemory.default(),
                graphicsDevices: [VMModelFieldGraphicDevice.default(osType: osType)],
                storageDevices: [VMModelFieldStorageDevice.default()],
                networkDevices: [VMModelFieldNetworkDevice.default()],
                pointingDevices: [VMModelFieldPointingDevice(type: .USBScreenCoordinatePointing)],
                audioDevices: [VMModelFieldAudioDevice.default()],
                directorySharingDevices: [],
                linuxFeatures: .recommended
            )
        }
    }
    
    
    func writeConfigToFile(path: URL) -> VMOSResultVoid {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(self)
            guard let content = String(data: data, encoding: .utf8) else {
                return .failure("failed to parse to utf8")
            }
            try content.write(to: path, atomically: true, encoding: .utf8)
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
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(self)
            guard let content = String(data: data, encoding: .utf8) else {
                return .failure("failed to parse to utf8")
            }
            try content.write(to: path, atomically: true, encoding: .utf8)
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
    let rootPath: URL
    let state: VMStateModel
    let config: VMConfigModel

    var id: URL { rootPath.standardizedFileURL }
    
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
    
    var screenshotURL: URL {
        rootPath.appending(path: "screenshot.png")
    }

    var savedMachineStateURL: URL {
        rootPath.appending(path: "MachineState.vzvmsave")
    }

    var guestAgentEnrollmentDirectoryURL: URL {
        rootPath.appending(path: ".EZVMAgent", directoryHint: .isDirectory)
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

    var hasConvertibleRawDisk: Bool {
        config.storageDevices.contains { $0.type == .Block && $0.format == .raw }
    }

    func convertPrimaryRawDiskToASIF() -> VMOSResultVoid {
        guard let index = config.storageDevices.firstIndex(where: { $0.type == .Block && $0.format == .raw }) else {
            return .failure("This virtual machine has no raw block disk to convert.")
        }

        let sourceDevice = config.storageDevices[index]
        let sourceURL = rootPath.appending(path: sourceDevice.imagePath)
        let destinationName = sourceURL.deletingPathExtension().lastPathComponent + ".asif"
        let destinationURL = rootPath.appending(path: destinationName)
        let backupURL = sourceURL.appendingPathExtension("raw-backup")
        let configBackupURL = configURL.appendingPathExtension("pre-asif-backup")

        guard !FileManager.default.fileExists(atPath: destinationURL.path(percentEncoded: false)) else {
            return .failure("An ASIF disk already exists at \(destinationURL.lastPathComponent).")
        }
        guard !FileManager.default.fileExists(atPath: backupURL.path(percentEncoded: false)) else {
            return .failure("A previous raw disk backup already exists at \(backupURL.lastPathComponent). Move it before converting again.")
        }

        let conversion = VMDiskImageManager.convertRawToASIF(sourceURL: sourceURL, destinationURL: destinationURL)
        if case .failure = conversion { return conversion }

        var storageDevices = config.storageDevices
        storageDevices[index] = VMModelFieldStorageDevice(
            type: .Block,
            size: sourceDevice.size,
            imagePath: destinationName,
            format: .asif
        )
        let updatedConfig = VMConfigModel(
            type: config.type,
            name: config.name,
            remark: config.remark,
            cpu: config.cpu,
            memory: config.memory,
            graphicsDevices: config.graphicsDevices,
            storageDevices: storageDevices,
            networkDevices: config.networkDevices,
            pointingDevices: config.pointingDevices,
            audioDevices: config.audioDevices,
            directorySharingDevices: config.directorySharingDevices,
            linuxFeatures: config.linuxFeatures
        )

        var movedSourceToBackup = false
        do {
            if !FileManager.default.fileExists(atPath: configBackupURL.path(percentEncoded: false)) {
                try FileManager.default.copyItem(at: configURL, to: configBackupURL)
            }
            try FileManager.default.moveItem(at: sourceURL, to: backupURL)
            movedSourceToBackup = true
            try updatedConfig.writeConfigToFile(path: configURL).get()
            return .success
        } catch {
            if movedSourceToBackup {
                try? FileManager.default.moveItem(at: backupURL, to: sourceURL)
            }
            try? FileManager.default.removeItem(at: destinationURL)
            return .failure("The ASIF image was created, but the VM configuration could not be updated: \(error.localizedDescription)")
        }
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

private extension VMOSResultVoid {
    func get() throws {
        if case .failure(let message) = self {
            throw NSError(domain: "EZVM.Configuration", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }
}

#endif
