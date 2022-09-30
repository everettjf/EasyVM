//
//  VMModelFieldAudioDevice.swift
//  EasyVM
//
//  Created by everettjf on 2022/8/24.
//

import Foundation

struct VMModelFieldAudioDevice: Decodable, CustomStringConvertible {
    
    enum DeviceType : String, CaseIterable, Identifiable, Decodable {
        case InputStream, OutputStream
        var id: Self { self }
    }
    let type: DeviceType
    
    var description: String {
        return "\(type)"
    }
    
    static func `defaults`() -> [VMModelFieldAudioDevice] {
        return [
            VMModelFieldAudioDevice(type:.InputStream),
            VMModelFieldAudioDevice(type:.OutputStream),
        ]
    }
}
