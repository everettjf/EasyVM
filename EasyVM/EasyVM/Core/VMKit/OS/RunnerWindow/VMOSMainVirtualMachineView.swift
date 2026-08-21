//
//  VMOSMainViewForMacOS.swift
//  EasyVM
//
//  Created by everettjf on 2022/10/3.
//

import SwiftUI
import AppKit

#if arch(arm64)
struct VMOSMainVirtualMachineView: View {
    @Environment(\.dismissWindow) private var dismissWindow
    let rootPath: URL
    let recoveryMode: Bool
    @State private var runtimeState = VMRuntimeState()
    @State private var isShowingCloseConfirmation = false
    
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
                        .textSelection(.enabled)
                    HStack {
                        Button("Copy Error", systemImage: "doc.on.doc") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(errorMessage, forType: .string)
                        }
                        Button("Export Diagnostics", systemImage: "square.and.arrow.up") {
                            do {
                                _ = try EasyVMDiagnostics.export()
                            } catch let error as CocoaError where error.code == .userCancelled {
                                // The save panel was intentionally dismissed.
                            } catch {
                                EasyVMLog.error("Diagnostic export failed: \(error.localizedDescription)")
                            }
                        }
                    }
                }
                .padding(40)
                .background(.regularMaterial)
                .clipShape(.rect(cornerRadius: 16))
            }

            if runtimeState.isCloseInProgress {
                VStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.large)
                    Text(runtimeState.phase == .saving ? "Saving Virtual Machine State…" : "Stopping Virtual Machine…")
                        .font(.headline)
                    Text("This window will close automatically when it is safe.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(28)
                .background(.regularMaterial, in: .rect(cornerRadius: 16))
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

                    Divider()

                    Button("Force Stop", systemImage: "stop.circle", role: .destructive) {
                        runtimeState.forceStop()
                    }
                    .disabled(!runtimeState.canForceStop)
                    .help("Immediately stop the virtual machine when the guest does not respond")
                }
            }
        }
        .navigationTitle(rootPath.deletingPathExtension().lastPathComponent)
        .background {
            VMWindowCloseObserver {
                runtimeState.needsCloseConfirmation
            } shouldBlock: {
                runtimeState.isCloseInProgress
            } onCloseAttempt: {
                isShowingCloseConfirmation = true
            }
        }
        .alert("Save State and Close?", isPresented: $isShowingCloseConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Save State and Close") {
                runtimeState.saveAndStopForWindowClose()
            }
        } message: {
            Text("EasyVM will save the virtual machine’s current state, stop it, and then close this window. You can resume from the same state next time.")
        }
        .onChange(of: runtimeState.phase) { _, phase in
            guard phase.shouldDismissMachineWindow else { return }
            dismissWindow(
                id: recoveryMode ? "start-machine-recovery" : "start-machine",
                value: rootPath
            )
        }
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
