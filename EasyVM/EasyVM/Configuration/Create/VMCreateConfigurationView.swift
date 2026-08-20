//
//  VMConfigurationView.swift
//  EasyVM
//
//  Created by everettjf on 2022/9/12.
//

import SwiftUI


#if arch(arm64)
struct VMCreateConfigurationView: View {
    
    var body: some View {
        Form {
            Section ("CPU / Memory") {
                VMConfigurationCPUView()
                VMConfigurationMemoryView()
            }
            
            Section ("Display / Storage / Network") {
                VMConfigurationGraphicDevicesView()
                VMConfigurationStorageDevicesView()
                VMConfigurationNetworkDevicesView()
                
            }
            Section ("Pointing / Audio") {
                VMConfigurationPointingDevicesView()
                VMConfigurationAudioDevicesView()
            }
            Section("Sharing Directory") {
                VMConfigurationDirectorySharingDevicesView()
            }
            VMLinuxFeaturesConfigurationSection()
        }
        .formStyle(.grouped)
    }
}

struct VMLinuxFeaturesConfigurationSection: View {
    @EnvironmentObject private var configData: VMConfigurationViewStateObject
    @AppStorage(EasyVMExperimentalFeatures.efiSecureBootKey) private var efiSecureBootEnabled = false

    var body: some View {
        if configData.osType == .linux {
            Section("Linux Integration") {
                Toggle("Rosetta for x86_64 Linux binaries", isOn: $configData.linuxFeatures.rosettaEnabled)
                Toggle("Rosetta translation cache", isOn: $configData.linuxFeatures.rosettaCachingEnabled)
                    .disabled(!configData.linuxFeatures.rosettaEnabled)
                Toggle("Dynamic memory balloon", isOn: $configData.linuxFeatures.memoryBalloonEnabled)
                Toggle("Virtio entropy source", isOn: $configData.linuxFeatures.entropyEnabled)
                Toggle("Virtio socket", isOn: $configData.linuxFeatures.virtioSocketEnabled)
                Toggle("UEFI Secure Boot", isOn: $configData.linuxFeatures.secureBootEnabled)
                    .disabled(!secureBootAvailable)

                if configData.linuxFeatures.rosettaEnabled {
                    Text("In the guest, mount the VirtioFS tag ‘rosetta’ and configure binfmt_misc. EasyVM installs the host Rosetta component when the VM is created.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if !secureBootAvailable {
                    Text("Secure Boot requires macOS 27 and the EFI Secure Boot experimental feature in Settings.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var secureBootAvailable: Bool {
        VirtualizationCapability.efiSecureBoot.isAvailable && efiSecureBootEnabled
    }
}

struct VMConfigurationView_Previews: PreviewProvider {
    static var previews: some View {
        VMCreateConfigurationView()
            .frame(width: 700, height:1000)
    }
}


#endif
