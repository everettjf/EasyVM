//
//  VMEditConfigurationView.swift
//  EasyVM
//
//  Created by everettjf on 2022/10/3.
//

import SwiftUI


#if arch(arm64)
struct VMEditConfigurationView: View {
    @Environment(\.presentationMode) var presentationMode
    
    @ObservedObject var configData: VMConfigurationViewStateObject
    let model: VMModel
    
    init(model: VMModel) {
        self.model = model
        self.configData = VMConfigurationViewStateObject(configModel: model.config)
    }
    
    var body: some View {
        content
            .environmentObject(configData)
            .frame(width: 500, height: 600)
    }
    
    var content: some View {
        VStack {
            Form {
                Section ("Basic") {
                    TextField("Name", text: $configData.name).lineLimit(1)
                    TextField("Description", text:$configData.remark).lineLimit(3, reservesSpace: true)
                }
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
            }
            .formStyle(.grouped)
            
            HStack {
                Spacer()
                Button {
                    presentationMode.wrappedValue.dismiss()
                } label: {
                    Text("Cancel")
                        .frame(width: 70)
                }
                Button {
                    // save
                    saveConfig()
                    
                    // dismiss
                    presentationMode.wrappedValue.dismiss()
                } label: {
                    Text("Save")
                        .frame(width: 70)
                }

            }
            .padding(.all)
        }
    }
    
    
    func saveConfig() {
        let configModel = configData.getConfigModel()
        
        let writeResult = configModel.writeConfigToFile(path: model.configURL)
        if case let .failure(error) = writeResult {
            print("failed save config : \(error)")
            return
        }
        
        print("succeed save")
        
        NotificationCenter.default.post(name: AppConfigManager.NewVMChangedNotification, object: nil)
    }
}
//
//struct VMEditConfigurationView_Previews: PreviewProvider {
//    static var previews: some View {
//        VMEditConfigurationView()
//            .frame(width: 700, height:1000)
//    }
//}


#endif
