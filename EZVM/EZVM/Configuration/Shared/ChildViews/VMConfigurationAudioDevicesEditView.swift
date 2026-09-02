//
//  VMConfigurationAudioDevicesEditView.swift
//  EZVM
//
//  Created by everettjf on 2022/9/30.
//

import SwiftUI

#if arch(arm64)
struct VMConfigurationAudioDevicesEditView: View {
    @Environment(VMConfigurationViewStateObject.self) var configData
    
    @Environment(\.dismiss) private var dismiss
    
    @State private var inputType: VMModelFieldAudioDevice.DeviceType = .InputStream
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section("New Audio Device") {
                    Picker("Access", selection: $inputType) {
                        ForEach(VMModelFieldAudioDevice.DeviceType.allCases) { item in
                            Label(item.displayName, systemImage: item.systemImage).tag(item)
                        }
                    }
                    Text("Microphone access still requires permission in System Settings. Speakers do not require additional permission.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Add Audio Device", systemImage: "plus") { addDevice() }
                }
                Section("Current Devices") {
                    ForEach(configData.audioDevices) { item in
                        HStack {
                            Label(item.data.description, systemImage: item.data.type.systemImage)
                            Spacer()
                            Button(role: .destructive) { configData.audioDevices.removeAll { $0.id == item.id } } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("Remove \(item.data.description)")
                        }
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Done") { dismiss() }
            }
            .padding()
        }
        .frame(minWidth: 500, minHeight: 380)
    }
    
    
    private func addDevice() {
        let device = VMModelFieldAudioDevice(type: inputType)
        configData.audioDevices.append(VMModelFieldAudioDeviceItemModel(data: device))
    }
}

struct VMConfigurationAudioDevicesEditView_Previews: PreviewProvider {
    static var previews: some View {
        VMConfigurationAudioDevicesEditView()
            .environment(VMConfigurationViewStateObject())
            .frame(height: 600)
    }
}


#endif
