//
//  VMOSRunner.swift
//  EasyVM
//
//  Created by everettjf on 2022/10/5.
//

import Foundation
import Virtualization

protocol VMOSRunner {
    
    func createConfiguration(model: VMModel) -> VMOSResult<VZVirtualMachineConfiguration, String>
}


class VMOSRunnerFactory {
    
    static func getRunner(_ osType: VMOSType) -> VMOSRunner {
        switch osType {
        case .macOS:
            return VMOSRunnerForMacOS()
        case .linux:
            return VMOSRunnerForLinux()
        }
    }
}
