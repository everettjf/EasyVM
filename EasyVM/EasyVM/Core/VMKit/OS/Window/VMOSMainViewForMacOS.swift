//
//  VMOSMainViewForMacOS.swift
//  EasyVM
//
//  Created by everettjf on 2022/10/3.
//

import SwiftUI

struct VMOSMainViewForMacOS: View {
    let rootPath: URL
    
    var body: some View {
        VStack {
            Text("root path : \(rootPath.path(percentEncoded: false))")
        }
    }
}

struct VMOSMainViewForMacOS_Previews: PreviewProvider {
    static var previews: some View {
        VMOSMainViewForMacOS(rootPath: URL(filePath: "/Users/everettjf/Downloads/MyVirtualMachine"))
    }
}
