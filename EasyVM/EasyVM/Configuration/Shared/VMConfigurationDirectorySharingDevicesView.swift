//
//  VMConfigurationDirectorySharingDevicesView.swift
//  EasyVM
//
//  Created by everettjf on 2022/10/5.
//

import SwiftUI

#if arch(arm64)
struct VMConfigurationDirectorySharingDevicesView: View {
    @EnvironmentObject var configData: VMConfigurationViewStateObject
    @State var showingEditView = false
    
    
    var body: some View {
        content
            .sheet(isPresented: $showingEditView) {
                VMConfigurationDirectorySharingDevicesEditView()
            }
    }
    
    var content: some View {
        LabeledContent("Directory Sharing") {
            VStack(alignment: .trailing) {
                List(configData.directorySharingDevices) { item in
                    HStack {
                        Spacer()
                        Text("\(String(describing: item.data))")
                            .lineLimit(5)
                            .multilineTextAlignment(.trailing)
                    }
                }
                .frame(width:400)
                
                HStack {
                    Spacer()
                    Button {
                        showingEditView.toggle()
                    } label: {
                        Image(systemName: "slider.vertical.3")
                    }
                    
                }
            }
        }
    }
}

struct VMConfigurationDirectorySharingDevicesView_Previews: PreviewProvider {
    static var previews: some View {
        Form {
            VMConfigurationDirectorySharingDevicesView()
                .environmentObject(VMConfigurationViewStateObject())
        }
        .formStyle(.grouped)
    }
}


#endif
