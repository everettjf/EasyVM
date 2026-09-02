//
//  VMConfigurationView.swift
//  EZVM
//
//  Created by everettjf on 2022/9/12.
//

import SwiftUI
import Virtualization


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
    @Environment(VMConfigurationViewStateObject.self) private var configData

    var body: some View {
        @Bindable var configData = configData
        if configData.osType == .linux {
            Section("Linux Integration") {
                Toggle("Rosetta for x86_64 Linux binaries", isOn: $configData.linuxFeatures.rosettaEnabled)
                Toggle("Rosetta translation cache", isOn: $configData.linuxFeatures.rosettaCachingEnabled)
                    .disabled(!configData.linuxFeatures.rosettaEnabled)
                Toggle("Dynamic memory balloon", isOn: $configData.linuxFeatures.memoryBalloonEnabled)
                Toggle("Virtio entropy source", isOn: $configData.linuxFeatures.entropyEnabled)
                Toggle("Virtio socket", isOn: $configData.linuxFeatures.virtioSocketEnabled)
                Toggle("Nested virtualization", isOn: $configData.linuxFeatures.nestedVirtualizationEnabled)
                    .disabled(!VZGenericPlatformConfiguration.isNestedVirtualizationSupported)
                Toggle("UEFI Secure Boot", isOn: $configData.linuxFeatures.secureBootEnabled)
                    .disabled(!secureBootAvailable)

                if configData.linuxFeatures.rosettaEnabled {
                    Text("In the guest, mount the VirtioFS tag ‘rosetta’ and configure binfmt_misc. EZVM installs the host Rosetta component when the VM is created.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if !secureBootAvailable {
                    Text("Secure Boot requires macOS 27.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if !VZGenericPlatformConfiguration.isNestedVirtualizationSupported {
                    Text("Nested virtualization requires an M3 or newer Mac. The VM remains portable and can run with this option disabled on older hosts.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var secureBootAvailable: Bool {
        VirtualizationCapability.efiSecureBoot.isAvailable
    }
}

struct VMConfigurationView_Previews: PreviewProvider {
    static var previews: some View {
        VMCreateConfigurationView()
            .frame(width: 700, height:1000)
    }
}


#endif
