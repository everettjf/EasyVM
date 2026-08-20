//
//  CreatePhaseConfigurationView.swift
//  EasyVM
//
//  Created by everettjf on 2022/9/12.
//

import SwiftUI
import Virtualization


#if arch(arm64)
class CreatePhaseConfigurationViewHandler: VMCreateStepperGuidePhaseHandler {
    
    func verifyForm(context: VMCreateStepperGuidePhaseContext) -> VMOSResultVoid {
        guard context.formData.provisionsMacGuest else { return .success }
        guard context.configData.osType == .macOS else {
            return .failure("Guest provisioning is available only for macOS virtual machines.")
        }
        guard #available(macOS 27.0, *),
              UserDefaults.standard.bool(forKey: EasyVMExperimentalFeatures.guestProvisioningKey) else {
            return .failure("Enable macOS guest provisioning in EasyVM Settings on a macOS 27 host.")
        }
        guard context.formData.provisioningPassword == context.formData.provisioningPasswordConfirmation else {
            return .failure("The guest account passwords do not match.")
        }
        do {
            let options = VZMacGuestProvisioningOptions()
            options.fullName = context.formData.provisioningFullName
            options.username = context.formData.provisioningUsername
            options.password = context.formData.provisioningPassword
            options.logsInAutomatically = context.formData.provisioningAutomaticLogin
            options.enablesRemoteLogin = context.formData.provisioningRemoteLogin
            try options.validate()
        } catch {
            return .failure("Guest provisioning settings are invalid: \(error.localizedDescription)")
        }
        return .success
    }
    func onStepMovedIn(context: VMCreateStepperGuidePhaseContext) async -> VMOSResultVoid {
        return .success
    }
}


struct CreatePhaseConfigurationView: View {
    @EnvironmentObject private var formData: VMCreateViewStateObject
    @EnvironmentObject private var configData: VMConfigurationViewStateObject
    @AppStorage(EasyVMExperimentalFeatures.guestProvisioningKey) private var guestProvisioningEnabled = false

    var body: some View {
        VStack(spacing: 14) {
            Text("Config Virtual Hardwares")
                .font(.title3)
                .padding(.all)
            VMCreateConfigurationView()
            if configData.osType == .macOS {
                guestProvisioningSection
            }
        }
    }

    private var guestProvisioningAvailable: Bool {
        VirtualizationCapability.guestProvisioning.isAvailable && guestProvisioningEnabled
    }

    private var guestProvisioningSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Create the first macOS account automatically", isOn: $formData.provisionsMacGuest)
                    .disabled(!guestProvisioningAvailable)

                if !guestProvisioningAvailable {
                    Text("Requires a macOS 27 host and the Guest Provisioning experimental feature in Settings. macOS 26 remains unaffected.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if formData.provisionsMacGuest {
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                        GridRow {
                            Text("Full name")
                            TextField("EasyVM User", text: $formData.provisioningFullName)
                        }
                        GridRow {
                            Text("Username")
                            TextField("easyvm", text: $formData.provisioningUsername)
                                .textContentType(.username)
                        }
                        GridRow {
                            Text("Password")
                            SecureField("Required", text: $formData.provisioningPassword)
                                .textContentType(.newPassword)
                        }
                        GridRow {
                            Text("Confirm")
                            SecureField("Repeat password", text: $formData.provisioningPasswordConfirmation)
                                .textContentType(.newPassword)
                        }
                    }
                    Toggle("Log in automatically", isOn: $formData.provisioningAutomaticLogin)
                    Toggle("Enable Remote Login (SSH)", isOn: $formData.provisioningRemoteLogin)
                    Text("The password is stored in this Mac’s Keychain until the VM’s first successful start. Guest macOS 26 and earlier ignore provisioning.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(4)
        } label: {
            Label("macOS 27 First-Boot Provisioning", systemImage: "person.crop.circle.badge.checkmark")
        }
    }
}

struct CreatePhaseConfigurationView_Previews: PreviewProvider {
    static var previews: some View {
        CreatePhaseConfigurationView()
            .environmentObject(VMCreateViewStateObject())
            .environmentObject(VMConfigurationViewStateObject())
    }
}


#endif
