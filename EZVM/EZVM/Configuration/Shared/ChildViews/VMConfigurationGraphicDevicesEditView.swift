//
//  VMConfigurationGraphicDevicesEditView.swift
//  EZVM
//
//  Created by everettjf on 2022/9/29.
//

import SwiftUI

#if arch(arm64)
struct VMConfigurationGraphicDevicesEditView: View {
    @Environment(VMConfigurationViewStateObject.self) var configData
    
    @Environment(\.dismiss) private var dismiss
    
    
    @State private var inputType: VMModelFieldGraphicDevice.DeviceType = .Mac
    @State private var inputWidth = 1920
    @State private var inputHeight = 1200
    @State private var inputPixelsPerInch = 80
    @State private var validationMessage: String?
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section("New Display") {
                    Picker("Type", selection: $inputType) {
                        ForEach(VMModelFieldGraphicDevice.DeviceType.allCases) { item in
                            Text(item.displayName).tag(item)
                        }
                    }
                    Picker("Resolution", selection: resolutionBinding) {
                        Text("1280 × 720").tag("1280x720")
                        Text("1920 × 1080").tag("1920x1080")
                        Text("1920 × 1200").tag("1920x1200")
                        Text("2560 × 1440").tag("2560x1440")
                        Text("Custom").tag("custom")
                    }
                    HStack {
                        TextField("Width", value: $inputWidth, format: .number)
                        Text("×").foregroundStyle(.secondary)
                        TextField("Height", value: $inputHeight, format: .number)
                    }
                    if inputType == .Mac {
                        Stepper("Pixel density: \(inputPixelsPerInch) ppi", value: $inputPixelsPerInch, in: 72...254, step: 8)
                    }
                    Text(inputType == .Mac ? "Mac displays are intended for macOS guests." : "Virtio displays are intended for Linux guests and can use Apple graphics or VirGL.")
                        .font(.caption).foregroundStyle(.secondary)
                    if let validationMessage {
                        Label(validationMessage, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    }
                    Button("Add Display", systemImage: "plus") { addDevice() }
                }
                Section("Current Devices") {
                    ForEach(configData.graphicDevices) { item in
                        HStack {
                            Label(item.data.description, systemImage: "display")
                            Spacer()
                            Button(role: .destructive) { configData.graphicDevices.removeAll { $0.id == item.id } } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless)
                                .disabled(configData.graphicDevices.count == 1)
                                .accessibilityLabel("Remove \(item.data.description)")
                        }
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                Text("At least one display is required.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }
            }
            .padding()
        }
        .frame(minWidth: 520, minHeight: 480)
    }

    private var resolutionBinding: Binding<String> {
        Binding(
            get: {
                let value = "\(inputWidth)x\(inputHeight)"
                return ["1280x720", "1920x1080", "1920x1200", "2560x1440"].contains(value) ? value : "custom"
            },
            set: { value in
                guard value != "custom" else { return }
                let components = value.split(separator: "x").compactMap { Int($0) }
                guard components.count == 2 else { return }
                inputWidth = components[0]
                inputHeight = components[1]
            }
        )
    }

    private func addDevice() {
        guard (640...7680).contains(inputWidth), (480...4320).contains(inputHeight) else {
            validationMessage = "Use a resolution between 640 × 480 and 7680 × 4320."
            return
        }
        validationMessage = nil
        let device = VMModelFieldGraphicDevice(type: inputType, width: inputWidth, height: inputHeight, pixelsPerInch: inputPixelsPerInch)
        
        configData.graphicDevices.append(VMModelFieldGraphicDeviceItemModel(data: device))
    }
}

struct VMConfigurationGraphicDevicesEditView_Previews: PreviewProvider {
    static var previews: some View {
        VMConfigurationGraphicDevicesEditView()
            .environment(VMConfigurationViewStateObject())
            .frame(height: 600)
    }
}


#endif
