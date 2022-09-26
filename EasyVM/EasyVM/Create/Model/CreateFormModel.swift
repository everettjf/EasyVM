//
//  CreateFormModel.swift
//  EasyVM
//
//  Created by everettjf on 2022/9/15.
//

import SwiftUI

class CreateFormModel: ObservableObject {
    // --- Form ---
    // phase
    @Published var osType: VMModelOSType = .macOS
    
    // phase
    @Published var name: String = "My New Virtual Machine"
    @Published var remark: String = "" // "The amazing new virtual machine created by EasyVM"
    
    // phase
    @Published var saveDirectory: String = ""

    // phase
    @Published var imagePath: String = ""
    
    // phase - confirguration
    
}
