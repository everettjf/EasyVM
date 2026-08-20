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
}

struct VMOSMainViewForMacOS_Previews: PreviewProvider {
    static var previews: some View {
        VMOSMainVirtualMachineView(rootPath: URL(filePath: "/Users/everettjf/Downloads/MyVirtualMachine"), recoveryMode: false)
    }
}

#endif
