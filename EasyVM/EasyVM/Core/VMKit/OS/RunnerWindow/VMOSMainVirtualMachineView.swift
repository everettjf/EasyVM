//
//  VMOSMainViewForMacOS.swift
//  EasyVM
//
//  Created by everettjf on 2022/10/3.
//

import SwiftUI

#if arch(arm64)
struct VMOSMainVirtualMachineView: View {
    let rootPath: URL
    let recoveryMode: Bool
    @StateObject private var runtimeState = VMRuntimeState()
    
    var body: some View {
        ZStack {
            VMOSInternalVirtualMachineView(
                rootPath: rootPath,
                recoveryMode: recoveryMode,
                runtimeState: runtimeState
            )

            if let errorMessage = runtimeState.errorMessage {
                VStack(spacing: 14) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 40))
                        .foregroundStyle(.orange)
                    Text("Virtual Machine Error")
                        .font(.title2.weight(.semibold))
                    Text(errorMessage)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(40)
                .background(.regularMaterial)
                .clipShape(.rect(cornerRadius: 16))
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if #available(macOS 27.0, *),
                   UserDefaults.standard.bool(forKey: EasyVMExperimentalFeatures.usbPassthroughKey) {
                    Menu("USB", systemImage: "cable.connector") {
                        if let message = runtimeState.usbStatusMessage {
                            Text(message)
                        }
                        if runtimeState.usbAccessories.isEmpty {
                            Text(runtimeState.canManageUSB ? "No accessible USB devices" : "Start the virtual machine to manage USB devices")
                        } else {
                            ForEach(runtimeState.usbAccessories) { accessory in
                                Button {
                                    runtimeState.toggleUSB(accessory.id)
                                } label: {
                                    Label {
                                        Text("\(accessory.name) — \(accessory.detail)")
                                    } icon: {
                                        Image(systemName: accessory.isAttached ? "checkmark.circle.fill" : "circle")
                                    }
                                }
                                .disabled(!runtimeState.canManageUSB)
                            }
                        }
                    }
                    .help("Attach or detach a host USB accessory")
                }

                if let target = runtimeState.balloonMemoryTarget,
                   let maximum = runtimeState.balloonMemoryMaximum {
                    Menu("Memory", systemImage: "memorychip") {
                        Text("Guest target: \(memoryDescription(target)) of \(memoryDescription(maximum))")
                        Divider()
                        ForEach([0.25, 0.5, 0.75, 1.0], id: \.self) { fraction in
                            Button("\(Int(fraction * 100))% — \(memoryDescription(UInt64(Double(maximum) * fraction)))") {
                                runtimeState.setBalloonMemory(fraction: fraction)
                            }
                            .disabled(!runtimeState.canManageBalloon)
                        }
                    }
                    .help("Request a Linux guest memory balloon target")
                }

                if runtimeState.canPause {
                    Button("Pause", systemImage: "pause") {
                        runtimeState.pause()
                    }
                    .accessibilityHint("Pause this virtual machine")
                }

                if runtimeState.canResume {
                    Button("Resume", systemImage: "play") {
                        runtimeState.resume()
                    }
                    .accessibilityHint("Resume this virtual machine")
                }

                Menu("Power", systemImage: "power") {
                    Button("Save State and Stop", systemImage: "square.and.arrow.down") {
                        runtimeState.saveAndStop()
                    }
                    .disabled(!runtimeState.canSave)

                    Button("Shut Down", systemImage: "power") {
                        runtimeState.requestStop()
                    }
                    .disabled(!runtimeState.canRequestStop)
                }
            }
        }
        .navigationTitle(rootPath.deletingPathExtension().lastPathComponent)
    }

    private func memoryDescription(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
    }
}

struct VMOSMainViewForMacOS_Previews: PreviewProvider {
    static var previews: some View {
        VMOSMainVirtualMachineView(rootPath: URL(filePath: "/Users/everettjf/Downloads/MyVirtualMachine"), recoveryMode: false)
    }
}

#endif
