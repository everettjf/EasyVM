//
//  CreatePhaseNameConfigView.swift
//  EasyVM
//
//  Created by everettjf on 2022/9/12.
//

import SwiftUI

struct CreatePhaseNameConfigView: View {
    
    @State private var name: String = "My New Virtual Machine"
    @State private var remark: String = ""
    
    var body: some View {
        VStack {
            Text("Choose the location for virtual machine:")
                .font(.title3)
                .padding(.all)
            
            Form {
                
                Section ("Basic") {
                    TextField("Name", text: $name).lineLimit(2)
                    
                    TextField("Description", text:$remark).lineLimit(3, reservesSpace: true)
                }
                
            }
            .formStyle(.grouped)
        }
    }
}

struct CreatePhaseNameConfigView_Previews: PreviewProvider {
    static var previews: some View {
        CreatePhaseNameConfigView()
    }
}
