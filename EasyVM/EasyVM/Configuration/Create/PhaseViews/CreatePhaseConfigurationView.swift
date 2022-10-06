//
//  CreatePhaseConfigurationView.swift
//  EasyVM
//
//  Created by everettjf on 2022/9/12.
//

import SwiftUI


class CreatePhaseConfigurationViewHandler: VMCreateStepperGuidePhaseHandler {
    
    func verifyForm(context: VMCreateStepperGuidePhaseContext) -> VMOSResultVoid {
        return .success
    }
    func onStepMovedIn(context: VMCreateStepperGuidePhaseContext) async -> VMOSResultVoid {
        
        DispatchQueue.main.async {
            if context.configData.osType == .linux {
                // make sure at least USB of image path for linux
                let imagePath = context.formData.imagePath
                if let _ = context.configData.storageDevices.firstIndex(where: {$0.data.type == .USB && $0.data.imagePath == imagePath}) {
                    // found : do nothing
                    print("already found usb for \(imagePath)")
                } else {
                    // not found, add
                    context.configData.storageDevices.append(VMModelFieldStorageDeviceItemModel(data: VMModelFieldStorageDevice(type: .USB, size: 0, imagePath: imagePath)))
                }
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
