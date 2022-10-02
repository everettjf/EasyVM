//
//  VMOSCreate.swift
//  EasyVM
//
//  Created by everettjf on 2022/10/1.
//

import Foundation

enum VMOSCreatorProgressInfo {
    case info(String)
    case error(String)
    case progress(Double)
}

protocol VMOSCreator {
    func create(model: VMModel, progress: @escaping (VMOSCreatorProgressInfo) -> Void) async -> VMOSResultVoid
}

class VMOSCreateFactory {
    static func getCreator(_ osType: VMOSType) -> VMOSCreator {
        return VMOSCreatorForMacOS()
    }
}

