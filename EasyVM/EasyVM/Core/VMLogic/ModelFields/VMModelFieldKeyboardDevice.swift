//
//  VMModelFieldKeyboardDevice.swift
//  EasyVM
//
//  Created by everettjf on 2022/8/24.
//

import Foundation

struct VMModelFieldKeyboardDevice: Decodable {
    let type: String
    
    init(type: String) {
        self.type = type
    }
    
    static func `default`() -> VMModelFieldKeyboardDevice {
        return VMModelFieldKeyboardDevice(type: "usb")
    }
    
    
}
