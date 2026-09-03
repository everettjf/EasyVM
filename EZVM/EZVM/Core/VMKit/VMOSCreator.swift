//
//  VMOSCreate.swift
//  EZVM
//
//  Created by everettjf on 2022/10/1.
//

import Foundation

#if arch(arm64)
enum VMOSCreatorProgressInfo {
    case info(String)
    case error(String)
    case progress(Double)
}

@MainActor
protocol VMOSCreator {
    func create(
        model: VMModel,
        provisioningCredential: VMGuestProvisioningCredential?,
        progress: @escaping (VMOSCreatorProgressInfo) -> Void
    ) async -> VMOSResultVoid
}

extension VMOSCreator {
    func create(
        model: VMModel,
        progress: @escaping (VMOSCreatorProgressInfo) -> Void
    ) async -> VMOSResultVoid {
        await create(model: model, provisioningCredential: nil, progress: progress)
    }
}

@MainActor
class VMOSCreateFactory {
    static func getCreator(_ osType: VMOSType) -> VMOSCreator {
        switch osType {
        case .macOS:
            return VMOSCreatorForMacOS()
        case .linux:
            return VMOSCreatorForLinux()
        }
    }
}


class VMOSCreatorUtil {
    static func createVMBundle(
        transaction: VMCreationDirectoryTransaction,
        allowedExistingItemNames: Set<String>? = nil
    ) async throws {
        try transaction.createRoot(allowedExistingItemNames: allowedExistingItemNames)
    }
}

#endif
