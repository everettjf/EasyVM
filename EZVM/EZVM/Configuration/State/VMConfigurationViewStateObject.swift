//
//  VMConfigurationViewState.swift
//  EZVM
//
//  Created by everettjf on 2022/9/29.
//

import Foundation
import SwiftUI
import Observation


#if arch(arm64)
struct VMModelFieldGraphicDeviceItemModel: Identifiable {
    let id = UUID()
    let data: VMModelFieldGraphicDevice
}

struct VMModelFieldStorageDeviceItemModel: Identifiable {
    let id = UUID()
    let data: VMModelFieldStorageDevice
}

struct VMModelFieldNetworkDeviceItemModel: Identifiable {
    let id = UUID()
    let data: VMModelFieldNetworkDevice
}

struct VMModelFieldPointingDeviceItemModel: Identifiable {
    let id = UUID()
    let data: VMModelFieldPointingDevice
}

struct VMModelFieldAudioDeviceItemModel: Identifiable {
    let id = UUID()
    let data: VMModelFieldAudioDevice
}

struct VMModelFieldDirectorySharingDeviceItemModel: Identifiable {
    let id = UUID()
    let data: VMModelFieldDirectorySharingDevice
}


@MainActor
@Observable
class VMConfigurationViewStateObject {
    var osType: VMOSType = .macOS
    
    var name: String = ""
    var remark: String = ""
    
    var cpuCount: Int = 1
    var memorySize: UInt64 = 1024 * 1024 * 1024 * 4

    var graphicDevices: [VMModelFieldGraphicDeviceItemModel] = []
    var storageDevices: [VMModelFieldStorageDeviceItemModel] = []
    var networkDevices: [VMModelFieldNetworkDeviceItemModel] = []
    
    var pointingDevices: [VMModelFieldPointingDeviceItemModel] = []
    var audioDevices: [VMModelFieldAudioDeviceItemModel] = []
    
    var directorySharingDevices: [VMModelFieldDirectorySharingDeviceItemModel] = []
    var linuxFeatures: VMLinuxFeatureConfiguration = .legacy
    
    convenience init() {
        // default
        self.init(configModel: VMConfigModel.createWithDefaultValues(osType: .macOS))
    }

    init(configModel: VMConfigModel) {
        self.setValuesWithConfigModel(configModel: configModel)
    }
    
    func setValuesWithConfigModel(configModel: VMConfigModel) {
        self.osType = configModel.type
        self.name = configModel.name
        self.remark = configModel.remark
        
        self.cpuCount = configModel.cpu.count
        self.memorySize = configModel.memory.size
        
        self.storageDevices.removeAll()
        for item in configModel.storageDevices {
            self.storageDevices.append(VMModelFieldStorageDeviceItemModel(data: item))
        }
        self.graphicDevices.removeAll()
        for item in configModel.graphicsDevices {
            self.graphicDevices.append(VMModelFieldGraphicDeviceItemModel(data: item))
        }
        self.networkDevices.removeAll()
        for item in configModel.networkDevices {
            self.networkDevices.append(VMModelFieldNetworkDeviceItemModel(data: item))
        }
        self.pointingDevices.removeAll()
        for item in configModel.pointingDevices {
            self.pointingDevices.append(VMModelFieldPointingDeviceItemModel(data: item))
        }
        self.audioDevices.removeAll()
        for item in configModel.audioDevices {
            self.audioDevices.append(VMModelFieldAudioDeviceItemModel(data: item))
        }
        self.directorySharingDevices = configModel.directorySharingDevices.map(VMModelFieldDirectorySharingDeviceItemModel.init(data:))
        self.linuxFeatures = configModel.linuxFeatures ?? .legacy
    }
    
    func resetDefaultConfig() {
        let defaultConfig = VMConfigModel.createWithDefaultValues(osType: osType)
        setValuesWithConfigModel(configModel: defaultConfig)
    }
    
    func getConfigModel() -> VMConfigModel {
        
        let cpu = VMModelFieldCPU(count: self.cpuCount)
        let memory = VMModelFieldMemory(size: self.memorySize)
        let graphicDevices = self.graphicDevices.map({$0.data})
        let storageDevices = self.storageDevices.map({$0.data})
        let networkDevices = self.networkDevices.map({$0.data})
        let pointingDevices = self.pointingDevices.map({$0.data})
        let audioDevices = self.audioDevices.map({$0.data})
        let directorySharingDevices = self.directorySharingDevices.map({$0.data})
        
        return VMConfigModel(type: osType, name: name, remark: remark, cpu: cpu, memory: memory, graphicsDevices: graphicDevices, storageDevices: storageDevices, networkDevices: networkDevices, pointingDevices: pointingDevices, audioDevices: audioDevices, directorySharingDevices: directorySharingDevices, linuxFeatures: osType == .linux ? linuxFeatures : nil)
    }

    @discardableResult
    func addSharedDirectory(_ url: URL, readOnly: Bool = false) -> Bool {
        let normalizedURL = url.standardizedFileURL
        guard !directorySharingDevices.contains(where: { device in
            device.data.items.contains { $0.path.standardizedFileURL == normalizedURL }
        }) else { return false }

        let item = VMModelFieldDirectorySharingDevice.SharingItem(
            name: url.lastPathComponent,
            path: normalizedURL,
            readOnly: readOnly
        )

        if osType == .macOS,
           let index = directorySharingDevices.firstIndex(where: { $0.data.tag == VMModelFieldDirectorySharingDevice.autoMoundTag }) {
            let existing = directorySharingDevices[index].data
            directorySharingDevices[index] = VMModelFieldDirectorySharingDeviceItemModel(
                data: VMModelFieldDirectorySharingDevice(tag: existing.tag, items: existing.items + [item])
            )
        } else {
            let tag = osType == .macOS
                ? VMModelFieldDirectorySharingDevice.autoMoundTag
                : nextLinuxShareTag(for: url.lastPathComponent)
            directorySharingDevices.append(
                VMModelFieldDirectorySharingDeviceItemModel(
                    data: VMModelFieldDirectorySharingDevice(tag: tag, items: [item])
                )
            )
        }
        return true
    }

    func removeSharedDirectory(deviceID: UUID, path: URL) {
        guard let index = directorySharingDevices.firstIndex(where: { $0.id == deviceID }) else { return }
        let device = directorySharingDevices[index].data
        let remaining = device.items.filter { $0.path.standardizedFileURL != path.standardizedFileURL }
        if remaining.isEmpty {
            directorySharingDevices.remove(at: index)
        } else {
            directorySharingDevices[index] = VMModelFieldDirectorySharingDeviceItemModel(
                data: VMModelFieldDirectorySharingDevice(tag: device.tag, items: remaining)
            )
        }
    }

    func setSharedDirectoryReadOnly(deviceID: UUID, path: URL, readOnly: Bool) {
        guard let index = directorySharingDevices.firstIndex(where: { $0.id == deviceID }) else { return }
        let device = directorySharingDevices[index].data
        let updated = device.items.map { item in
            guard item.path.standardizedFileURL == path.standardizedFileURL else { return item }
            return VMModelFieldDirectorySharingDevice.SharingItem(
                name: item.name,
                path: item.path,
                readOnly: readOnly
            )
        }
        directorySharingDevices[index] = VMModelFieldDirectorySharingDeviceItemModel(
            data: VMModelFieldDirectorySharingDevice(tag: device.tag, items: updated)
        )
    }

    private func nextLinuxShareTag(for folderName: String) -> String {
        let allowed = folderName.lowercased().unicodeScalars.map { scalar -> Character in
            scalar.isASCII && CharacterSet.alphanumerics.contains(scalar) ? Character(String(scalar)) : "_"
        }
        let base = String(allowed).trimmingCharacters(in: CharacterSet(charactersIn: "_")).prefix(24)
        let root = base.isEmpty ? "shared" : String(base)
        let existing = Set(directorySharingDevices.map { $0.data.tag })
        if !existing.contains(root) { return root }
        var suffix = 2
        while existing.contains("\(root)_\(suffix)") { suffix += 1 }
        return "\(root)_\(suffix)"
    }
    
}
#endif
