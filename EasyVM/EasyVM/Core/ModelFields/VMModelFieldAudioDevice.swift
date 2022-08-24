//
//  VMModelFieldAudioDevice.swift
//  EasyVM
//
//  Created by everettjf on 2022/8/24.
//

import Foundation

struct VMModelFieldAudioDevice: Decodable {
    let type: String
    
    init(type: String) {
        self.type = type
    }
    
    static func `defaults`() -> [VMModelFieldAudioDevice] {
        return [
            VMModelFieldAudioDevice(type: "input"),
            VMModelFieldAudioDevice(type: "output"),
        ]
    }
}
