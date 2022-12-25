//
//  VMOSCreate.swift
//  EasyVM
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

protocol VMOSCreator {
    func create(model: VMModel, progress: @escaping (VMOSCreatorProgressInfo) -> Void) async -> VMOSResultVoid
}

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
    
    static func createVMBundle(path: URL) async throws {
        return try await withCheckedThrowingContinuation { continuation in
            let bundleFd = mkdir(path.path(percentEncoded: false), S_IRWXU | S_IRWXG | S_IRWXO)
            if bundleFd == -1 {
                if errno == EEXIST {
                    let items = (try? FileManager.default.contentsOfDirectory(atPath: path.path())) ?? []
                    if (items.count >= 2) {
                        // if target directory contains more than 1 items
                        let error = "The base directory already exists."
                        continuation.resume(throwing: VMOSError.regularFailure(error))
                        return
                    } else {
                        continuation.resume(returning: ())
                        return
                    }
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

#endif
