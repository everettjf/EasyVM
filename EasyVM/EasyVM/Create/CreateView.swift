//
//  CreateView.swift
//  EasyVM
//
//  Created by everettjf on 2022/8/6.
//

import SwiftUI

struct CreateView: View {
    
    @State private var osType: VMModelOSType = .macOS
    @State private var name: String = "My New Virtual Machine"
    
    
    var body: some View {
        Form {
            Section {
                TextField("Name", text: $name).lineLimit(2)
                Picker("OS Type", selection: $osType) {
                    ForEach(VMModelOSType.allCases) { item in
                        Text(item.name).tag(item)
                    }
                }
                DirectorySelectTextField(name: "Save Directory")
            }
        }
    }
}

struct CreateView_Previews: PreviewProvider {
    static var previews: some View {
        CreateView()
    }
}
