//
//  VMOSType.swift
//  EasyVM
//
//  Created by everettjf on 2022/9/27.
//

import Foundation

enum VMOSType: String, Identifiable, CaseIterable, Hashable, Decodable, Encodable {
    case macOS = "macOS"
    case linux = "linux"
    
    var name: String { rawValue }
    var id: String { rawValue }
}
