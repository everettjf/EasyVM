//
//  VMOSResult.swift
//  EasyVM
//
//  Created by everettjf on 2022/9/27.
//

import Foundation

enum VMOSResult<Success, Failure> {
    case success(Success)
    case failure(Failure)
}


// simple for void result
enum VMOSResultVoid {
    case success
    case failure(String)
}


enum VMOSError: Error {
    case regularFailure(String)
}
