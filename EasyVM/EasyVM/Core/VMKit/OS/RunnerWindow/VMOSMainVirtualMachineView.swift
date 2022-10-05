//
//  VMOSMainViewForMacOS.swift
//  EasyVM
//
//  Created by everettjf on 2022/10/3.
//

import SwiftUI

struct VMOSMainVirtualMachineView: View {
    let rootPath: URL
    let recoveryMode: Bool
    
    var body: some View {
        VMOSInternalVirtualMachineView(rootPath: rootPath, recoveryMode: recoveryMode)
    }
}

struct VMOSMainViewForMacOS_Previews: PreviewProvider {
    static var previews: some View {
        VMOSMainVirtualMachineView(rootPath: URL(filePath: "/Users/everettjf/Downloads/MyVirtualMachine"), recoveryMode: false)
    }
}
