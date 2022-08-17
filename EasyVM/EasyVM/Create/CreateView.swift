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
    @State private var remark: String = ""
    @State private var vmDirectory: String = ""
    @State private var imagePath: String = ""
    
    @State private var cpuCount: Int = 1
    @State private var memorySize: Int = 1024 * 1024 * 2

    
    var body: some View {
        Form {
            Section ("Basic Information") {
                TextField("Name", text: $name).lineLimit(2)
                Picker("OS Type", selection: $osType) {
                    ForEach(VMModelOSType.allCases) { item in
                        Text(item.name).tag(item)
                    }
                }
                .pickerStyle(.inline)
                
                TextField("Save Directory", text: $vmDirectory)

                TextField("Image Path", text: $imagePath)
                
                TextField("Description", text:$remark).lineLimit(5, reservesSpace: true)
            }
            
            Section ("Machine Configuration") {
                Stepper {
                    Text("CPU Count : \(cpuCount)")
                } onIncrement: {
                    self.cpuCount += 1
                } onDecrement: {
                    self.cpuCount -= 1
                }
                
                TextField("Memory Size", value: $memorySize, format: .number)
                TextField("Disk Size", value: $memorySize, format: .number)
                
                List {
                    Text("1")
                    Text("1")
                    Text("1")
                    Text("1")
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct CreateView_Previews: PreviewProvider {
    static var previews: some View {
        CreateView()
            .frame(height:600)
    }
}
