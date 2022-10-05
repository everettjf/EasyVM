//
//  VMOSMainViewForMacOS.swift
//  EasyVM
//
//  Created by everettjf on 2022/10/3.
//

import SwiftUI





struct VMOSMainVirtualMachineView: View {
    let rootPath: URL
    
    var body: some View {
        VStack {
            HStack {
                Spacer()
                Text("root path : \(rootPath.path(percentEncoded: false))")
            }
            .frame(height: 20)
            
            VMOSInternalVirtualMachineView(rootPath: rootPath)
        }
    }
}

struct VMOSMainViewForMacOS_Previews: PreviewProvider {
    static var previews: some View {
        VMOSMainVirtualMachineView(rootPath: URL(filePath: "/Users/everettjf/Downloads/MyVirtualMachine"))
    }
}
