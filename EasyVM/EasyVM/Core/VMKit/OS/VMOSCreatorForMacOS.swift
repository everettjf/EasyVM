//
//  VMOSCreatorForMacOS.swift
//  EasyVM
//
//  Created by everettjf on 2022/10/1.
//

import Foundation
import Virtualization

class VMOSCreatorForMacOS : VMOSCreator {
    func create(vmModel: VMModel) async -> VMOSResultVoid {
        
        do {
            // create bundle
            let rootPath = vmModel.getRootPath()
            try await createVMBundle(path: rootPath)
            print("Create root bundle succeed")

            // load image
            let restoreImage = try await loadSystemImage(ipswURL: vmModel.imagePath)
            try await checkSystemImage(restoreImage: restoreImage)
            
            // create disk
            
            // create some files
            
        } catch {
            return .failure("\(error)")
        }
        
        return .success
    }
    
    private func checkSystemImage(restoreImage: VZMacOSRestoreImage) async throws {
        return try await withCheckedThrowingContinuation({ continuation in
            guard let macOSConfiguration = restoreImage.mostFeaturefulSupportedConfiguration else {
                continuation.resume(throwing: VMOSError.regularFailure("No supported configuration available."))
                return
            }

            if !macOSConfiguration.hardwareModel.isSupported {
                continuation.resume(throwing: VMOSError.regularFailure("macOSConfiguration configuration isn't supported on the current host."))
                return
            }

            continuation.resume(returning: ())
        })
    }
    
    private func loadSystemImage(ipswURL: URL) async throws -> VZMacOSRestoreImage {
        return try await withCheckedThrowingContinuation({ continuation in
            VZMacOSRestoreImage.load(from: ipswURL) { result in
                switch result {
                case let .failure(error):
                    continuation.resume(throwing: error)
                case let .success(systemImage):
                    continuation.resume(returning: systemImage)
                }
            }
        })
    }
    
    
    private func createVMBundle(path: URL) async throws {
        return try await withCheckedThrowingContinuation { continuation in
            let bundleFd = mkdir(path.path(), S_IRWXU | S_IRWXG | S_IRWXO)
            if bundleFd == -1 {
                if errno == EEXIST {
                    let error = "Failed to create VM.bundle: the base directory already exists."
                    continuation.resume(throwing: VMOSError.regularFailure(error))
                    return
                }
                continuation.resume(throwing: VMOSError.regularFailure("Failed to create VM.bundle."))
                return
            }

            let result = close(bundleFd)
            if result != 0 {
                continuation.resume(throwing: VMOSError.regularFailure("Failed to close VM.bundle."))
                return
            }
            continuation.resume(returning: ())
        }
    }
}
