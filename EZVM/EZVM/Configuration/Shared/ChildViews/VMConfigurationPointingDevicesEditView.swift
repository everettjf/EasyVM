//
//  VMConfigurationPointingDevicesEditView.swift
//  EZVM
//
//  Created by everettjf on 2022/9/30.
//

import SwiftUI


#if arch(arm64)
struct VMConfigurationPointingDevicesEditView: View {
    
    @Environment(VMConfigurationViewStateObject.self) var configData
    
    @Environment(\.dismiss) private var dismiss
    
    @State private var inputType: VMModelFieldPointingDevice.DeviceType = .USBScreenCoordinatePointing

    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section("New Pointing Device") {
                    Picker("Device", selection: $inputType) {
                        ForEach(VMModelFieldPointingDevice.DeviceType.allCases) { item in
                            Text(item.displayName).tag(item)
                        }
                    }
                    Text(inputType.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Add Pointing Device", systemImage: "plus") { addDevice() }
                }
                Section("Current Devices") {
                    ForEach(configData.pointingDevices) { item in
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.data.description)
                                Text(item.data.type.detail).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(role: .destructive) { configData.pointingDevices.removeAll { $0.id == item.id } } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless)
                                .disabled(configData.pointingDevices.count == 1)
                                .accessibilityLabel("Remove \(item.data.description)")
                        }
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                Text("At least one pointing device is required.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }
            }
            .padding()
        }
        .frame(minWidth: 500, minHeight: 380)
    }
    
    
    private func addDevice() {
        let device = VMModelFieldPointingDevice(type: inputType)
        configData.pointingDevices.append(VMModelFieldPointingDeviceItemModel(data: device))
    }
}

struct VMConfigurationPointingDevicesEditView_Previews: PreviewProvider {
    static var previews: some View {
        VMConfigurationPointingDevicesEditView()
            .environment(VMConfigurationViewStateObject())
            .frame(height: 600)
    }
}
#endif
