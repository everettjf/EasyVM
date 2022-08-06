//
//  VMModel.swift
//  EasyVM
//
//  Created by everettjf on 2022/8/6.
//

import Foundation
import SwiftUI


enum VMModelOSType: String, Identifiable, CaseIterable, Hashable {
    case macOS = "macOS"
    case linux = "linux"
    
    var name: String { rawValue }
    var id: String { rawValue }
}


struct VMModel: Identifiable {
    let id = UUID()
    
    let type: VMModelOSType
    let emoji: String
    let name: String
    let createdAt: Date
    let lastStartedAt: Date?
    let rootPath: String
    let remark: String = ""
}


let allVirtualMachines: [VMModel] = [
    VMModel(type: .macOS, emoji: "🍉",name: "My First macOS VM", createdAt:.now, lastStartedAt: .now, rootPath: "~/EasyVMData/My First macOS VM"),
    VMModel(type: .macOS, emoji: "🍩",name: "Amazing macOS VM", createdAt:.now, lastStartedAt: .now, rootPath: "~/EasyVMData/My First macOS VM"),
    VMModel(type: .linux, emoji: "🍧",name: "My Ubuntu", createdAt: .now, lastStartedAt: nil, rootPath: "~/EasyVMData/My Ubuntu"),
    VMModel(type: .linux, emoji: "🥨",name: "My Fedora", createdAt: .now, lastStartedAt: nil, rootPath: "~/EasyVMData/My Ubuntu"),
    VMModel(type: .linux, emoji: "🎂",name: "My Arch Linux", createdAt: .now, lastStartedAt: nil, rootPath: "~/EasyVMData/My Ubuntu"),
    VMModel(type: .linux, emoji: "🍪",name: "Debian Linux", createdAt: .now, lastStartedAt: nil, rootPath: "~/EasyVMData/My Ubuntu"),
]
