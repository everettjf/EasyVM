//
//  CreateFormModel.swift
//  EasyVM
//
//  Created by everettjf on 2022/9/15.
//

import SwiftUI

#if arch(arm64)
@MainActor
class VMCreateViewStateObject: ObservableObject {
    struct LogModel : Identifiable {
        let id = UUID()
        let time: String
        let log: String
        
        init(_ log: String) {
            let date = Date()
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "HH:mm:ss"
            self.time = dateFormatter.string(from: date)
            
            self.log = log
        }
    }
    
    
    // phase
    @Published var rootPath: String = ""
    @Published var baseDirectory: String = ""

    // phase
    @Published var imagePath: String = ""

    @Published var logs: [LogModel] = []

    @Published var installingProgress: Double = 0.0

    @Published var disablePreviousButton = false

    // creating phase status
    @Published var isCreating = false
    @Published var statusText: String = ""


    init() {
    }

    func addLog(_ log: String) {
        logs.insert(LogModel(log), at: 0)
        statusText = log
    }
    
    func changeProgress(_ percent: Double) {
        if percent > 1.0 {
            return
        }
        if percent < 0.0 {
            return
        }
        installingProgress = percent
    }
    
}


#endif
