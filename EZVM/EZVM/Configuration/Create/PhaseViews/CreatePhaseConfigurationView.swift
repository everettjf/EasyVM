//
//  CreatePhaseConfigurationView.swift
//  EZVM
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
        guard #available(macOS 27.0, *) else {
            return .failure("macOS guest provisioning requires a macOS 27 host.")
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
    @Environment(VMCreateViewStateObject.self) private var formData
    @Environment(VMConfigurationViewStateObject.self) private var configData

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
        VirtualizationCapability.guestProvisioning.isAvailable
    }

    private var guestProvisioningSection: some View {
        @Bindable var formData = formData
        return GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Create the first macOS account automatically", isOn: $formData.provisionsMacGuest)
                    .disabled(!guestProvisioningAvailable)

                if !guestProvisioningAvailable {
                    Text("Requires a macOS 27 host.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if formData.provisionsMacGuest {
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                        GridRow {
                            Text("Full name")
                            TextField("EZVM User", text: $formData.provisioningFullName)
                        }
                        GridRow {
                            Text("Username")
                            TextField("ezvm", text: $formData.provisioningUsername)
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
            .environment(VMCreateViewStateObject())
            .environment(VMConfigurationViewStateObject())
    }
}


#endif
