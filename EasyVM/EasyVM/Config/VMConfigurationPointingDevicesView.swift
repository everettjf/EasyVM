//
//  VMConfigurationPointingDevicesView.swift
//  EasyVM
//
//  Created by everettjf on 2022/9/30.
//

import SwiftUI

struct VMConfigurationPointingDevicesView: View {
    @EnvironmentObject var state: VMConfigurationViewState
    @State var showingEditView = false
    
    var body: some View {
        content
            .sheet(isPresented: $showingEditView) {
                VMConfigurationPointingDevicesEditView()
            }
    }
    var content: some View {
        
        LabeledContent("Pointing Devices") {
            VStack(alignment: .trailing) {
                List(state.pointingDevices) { item in
                    HStack {
                        Spacer()
                        Text("\(String(describing: item.data))")
                    }
                }
                .frame(width:400)
                
                VStack {
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

struct VMConfigurationPointingDevicesView_Previews: PreviewProvider {
    static var previews: some View {
        VMConfigurationPointingDevicesView()
            .environmentObject(VMConfigurationViewState())
    }
}
