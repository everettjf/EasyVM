//
//  VMConfigurationStorageDevicesEditView.swift
//  EZVM
//
//  Created by everettjf on 2022/9/30.
//

import SwiftUI

#if arch(arm64)
struct VMConfigurationStorageDevicesEditView: View {
    @Environment(VMConfigurationViewStateObject.self) var configData
    
    @Environment(\.dismiss) private var dismiss
    
    
    @State private var inputType: VMModelFieldStorageDevice.DeviceType = .USB
    @State private var inputFormat: VMDiskImageFormat = .asif
    @State private var inputSize: UInt64 = 64 * 1024 * 1024 * 1024
    @State private var inputPath = ""
    @State private var validationMessage: String?

    private var inputSizeGB: Binding<Int> {
        Binding(
            get: { Int(inputSize / 1_073_741_824) },
            set: { inputSize = UInt64($0) * 1_073_741_824 }
        )
    }
    
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section("New Storage Device") {
                    Picker("Kind", selection: $inputType) {
                        ForEach(VMModelFieldStorageDevice.DeviceType.allCases) { item in
                            Text(item.displayName).tag(item)
                        }
                    }
                    
                    if inputType == .Block {
                        Picker("Disk Format", selection: $inputFormat) {
                            ForEach(VMDiskImageFormat.allCases) { format in
                                Text(format.rawValue.uppercased()).tag(format)
                            }
                        }
                        Stepper(value: inputSizeGB, in: 10...2048, step: 8) {
                            LabeledContent("Capacity", value: "\(inputSizeGB.wrappedValue) GB")
                        }
                        Text(inputFormat == .asif ? "ASIF is optimized for macOS 27 and supports efficient snapshots." : "RAW is broadly compatible but uses more host storage.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        LabeledContent("ISO image") {
                            HStack {
                                Text(inputPath.isEmpty ? "No file selected" : URL(fileURLWithPath: inputPath).lastPathComponent)
                                    .foregroundStyle(inputPath.isEmpty ? .secondary : .primary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Button("Choose…") {
                                MacKitUtil.selectFile(title: "Choose *.iso file") { path in
                                    guard let path = path else {
                                        return
                                    }
                                    inputPath = path.path(percentEncoded: false)
                                }
                                }
                            }
                        }
                    }
                    if let validationMessage {
                        Label(validationMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                    Button("Add Storage Device", systemImage: "plus") { addDevice() }
                }
                Section("Current Devices") {
                    ForEach(configData.storageDevices) { item in
                        HStack {
                            Label(item.data.description, systemImage: item.data.type == .Block ? "internaldrive" : "opticaldiscdrive")
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Button(role: .destructive) { configData.storageDevices.removeAll { $0.id == item.id } } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless)
                                .disabled(configData.storageDevices.count == 1)
                                .accessibilityLabel("Remove \(item.data.description)")
                        }
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                Text("At least one virtual disk is required.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }
            }
            .padding()
        }
        .frame(minWidth: 540, minHeight: 480)
    }
    
    
    private func addDevice() {
        if inputType == .USB {
            guard !inputPath.isEmpty else {
                validationMessage = "Choose an ISO image first."
                return
            }
            guard inputPath.lowercased().hasSuffix(".iso") else {
                validationMessage = "Installation media must be an ISO file."
                return
            }
            guard FileManager.default.fileExists(atPath: inputPath) else {
                validationMessage = "The selected ISO image no longer exists."
                return
            }
        }
        validationMessage = nil
        let path = inputType == .Block ? "Disk-\(UUID().uuidString).\(inputFormat.fileExtension)" : inputPath
        let device = VMModelFieldStorageDevice(type: inputType, size: inputSize, imagePath: path, format: inputFormat)
        
        configData.storageDevices.append(VMModelFieldStorageDeviceItemModel(data: device))
    }
}

struct VMConfigurationStorageDevicesEditView_Previews: PreviewProvider {
    static var previews: some View {
        VMConfigurationStorageDevicesEditView()
            .environment(VMConfigurationViewStateObject())
            .frame(height: 600)
    }
}


#endif
