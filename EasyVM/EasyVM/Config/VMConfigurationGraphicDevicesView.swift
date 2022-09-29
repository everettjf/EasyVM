//
//  VMConfigurationGraphicsDevicesView.swift
//  EasyVM
//
//  Created by everettjf on 2022/9/29.
//

import SwiftUI

struct VMConfigurationGraphicDevicesView: View {
    
    @EnvironmentObject var state: VMConfigurationViewState
    
    @State var showingEditView = false
    
    var body: some View {
        content
            .sheet(isPresented: $showingEditView) {
                VMConfigurationGraphicDevicesEditView()
            }
    }
    
    var content: some View {
        
        LabeledContent("Graphics Devices") {
            VStack(alignment: .trailing) {
                
                List (state.graphicDevices) { item in
                    HStack {
                        Spacer()
                        Text("\(String(describing: item.data))")
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

struct VMConfigurationGraphicDevicesView_Previews: PreviewProvider {
    static var previews: some View {
        Form {
            Section("Section") {
                VMConfigurationGraphicDevicesView()
            }
        }
        .environmentObject(VMConfigurationViewState())
    }
}
