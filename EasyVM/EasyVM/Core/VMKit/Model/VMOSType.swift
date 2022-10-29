//
//  VMOSType.swift
//  EasyVM
//
//  Created by everettjf on 2022/9/27.
//

import Foundation

#if arch(arm64)
enum VMOSType: String, Identifiable, CaseIterable, Hashable, Decodable, Encodable {
    case macOS = "macOS"
    case linux = "linux"
    
    var name: String { rawValue }
    var id: String { rawValue }
}

#endif
