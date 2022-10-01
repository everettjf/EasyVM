//
//  VMOSCreate.swift
//  EasyVM
//
//  Created by everettjf on 2022/10/1.
//

import Foundation

protocol VMOSCreator {
    func create(vmModel: VMModel) async -> VMOSResultVoid
}

class VMOSCreateFactory {
    static func getCreator(_ osType: VMOSType) -> VMOSCreator {
        return VMOSCreatorForMacOS()
    }
}

