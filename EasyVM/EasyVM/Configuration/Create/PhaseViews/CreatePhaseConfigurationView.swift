//
//  CreatePhaseConfigurationView.swift
//  EasyVM
//
//  Created by everettjf on 2022/9/12.
//

import SwiftUI


#if arch(arm64)
class CreatePhaseConfigurationViewHandler: VMCreateStepperGuidePhaseHandler {
    
    func verifyForm(context: VMCreateStepperGuidePhaseContext) -> VMOSResultVoid {
        return .success
    }
    func onStepMovedIn(context: VMCreateStepperGuidePhaseContext) async -> VMOSResultVoid {
        
        if context.configData.osType == .linux {
            let imagePath = context.formData.imagePath
            if context.configData.storageDevices.contains(where: { $0.data.type == .USB && $0.data.imagePath == imagePath }) {
                print("already found usb for \(imagePath)")
            } else {
                context.configData.storageDevices.append(VMModelFieldStorageDeviceItemModel(data: VMModelFieldStorageDevice(type: .USB, size: 0, imagePath: imagePath)))
            }
        }
        
        
        return .success
    }
}


struct CreatePhaseConfigurationView: View {
    var body: some View {
        VStack {
            Text("Config Virtual Hardwares")
                .font(.title3)
                .padding(.all)
            VMCreateConfigurationView()
        }
    }
}

struct CreatePhaseConfigurationView_Previews: PreviewProvider {
    static var previews: some View {
        CreatePhaseConfigurationView()
    }
}


#endif
