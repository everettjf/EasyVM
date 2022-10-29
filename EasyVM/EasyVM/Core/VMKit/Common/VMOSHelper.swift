//
//  VMOSHelper.swift
//  EasyVM
//
//  Created by everettjf on 2022/10/1.
//

import Foundation


#if arch(arm64)
class VMOSHelper {
    
    // Create an empty disk image for the Virtual Machine.
    static func createEmptyDiskImage(filePath: URL, size: UInt64) -> VMOSResultVoid {
        let diskFd = open(filePath.path(percentEncoded: false), O_RDWR | O_CREAT, S_IRUSR | S_IWUSR)
        if diskFd == -1 {
            return .failure("Cannot create disk image.")
        }
        
        // 64GB disk space.
        var result = ftruncate(diskFd, 64 * 1024 * 1024 * 1024)
        if result != 0 {
            return .failure("ftruncate() failed.")
        }
        
        result = close(diskFd)
        if result != 0 {
            return .failure("Failed to close the disk image.")
        }
        return .success
    }
    
    // Create an empty disk image for the Virtual Machine.
    static func createEmptyDiskImage(filePath: URL, size: UInt64) async throws {
        return try await withCheckedThrowingContinuation({ continuation in
            let result = createEmptyDiskImage(filePath: filePath, size: size)
            if case let .failure(error) = result {
                continuation.resume(throwing: VMOSError.regularFailure(error))
                return
            }
            continuation.resume(returning: ())
        })
    }
}

#endif
