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
    enum SystemImageSelection: Hashable {
        case latestMacOS
        case catalog(VMSystemImageCatalogItem)
        case remoteURL(URL)
        case localFile(URL)

        var title: String {
            switch self {
            case .latestMacOS:
                return "Latest compatible macOS"
            case .catalog(let item):
                return item.name
            case .remoteURL(let url):
                return url.lastPathComponent.isEmpty ? url.absoluteString : url.lastPathComponent
            case .localFile(let url):
                return url.lastPathComponent
            }
        }

        var detail: String {
            switch self {
            case .latestMacOS:
                return "Downloaded from Apple when you create the virtual machine"
            case .catalog(let item):
                return VMImageStore.exists(fileName: Self.fileName(for: item))
                    ? "Ready in the image cache"
                    : "Downloaded when you create the virtual machine"
            case .remoteURL(let url):
                return url.absoluteString
            case .localFile(let url):
                return url.path(percentEncoded: false)
            }
        }

        private static func fileName(for item: VMSystemImageCatalogItem) -> String {
            let fallbackExtension = item.osType == .macOS ? "ipsw" : "iso"
            let ext = item.url.pathExtension.isEmpty ? fallbackExtension : item.url.pathExtension
            return "\(item.id).\(ext)"
        }
    }

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
    @Published var hasGeneratedNameSuggestion = false

    // phase
    @Published var imagePath: String = ""
    @Published var systemImageSelection: SystemImageSelection = .latestMacOS

    // macOS 27 first-boot provisioning. The password lives only in this
    // in-memory form and is moved to Keychain after the VM is installed.
    @Published var provisionsMacGuest = false
    @Published var provisioningFullName = "EasyVM User"
    @Published var provisioningUsername = "easyvm"
    @Published var provisioningPassword = ""
    @Published var provisioningPasswordConfirmation = ""
    @Published var provisioningAutomaticLogin = false
    @Published var provisioningRemoteLogin = false

    @Published var logs: [LogModel] = []

    @Published var installingProgress: Double = 0.0

    @Published var disablePreviousButton = false

    // creating phase status
    @Published var isCreating = false
    @Published var canCancelCreation = false
    @Published var statusText: String = ""
    @Published var creationStage: String = "Preparing"


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
