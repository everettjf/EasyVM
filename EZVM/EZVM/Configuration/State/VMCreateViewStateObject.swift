//
//  CreateFormModel.swift
//  EZVM
//
//  Created by everettjf on 2022/9/15.
//

import SwiftUI
import Observation

#if arch(arm64)
@MainActor
@Observable
class VMCreateViewStateObject {
    enum SystemImageSelection: Hashable {
        case latestMacOS
        case catalog(VMSystemImageCatalogItem)
        case preinstalled(VMPreinstalledImageCatalogItem)
        case remoteURL(URL)
        case localFile(URL)

        var title: String {
            switch self {
            case .latestMacOS:
                return "Latest compatible macOS"
            case .catalog(let item):
                return item.name
            case .preinstalled(let item):
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
            case .preinstalled(let item):
                return "Preinstalled image · downloaded and verified when you create the virtual machine · \(Self.formattedSize(item.downloadSize))"
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

        private static func formattedSize(_ bytes: Int64?) -> String {
            guard let bytes else { return "size unavailable" }
            return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
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
    var rootPath: String = ""
    var baseDirectory: String = ""
    var hasGeneratedNameSuggestion = false

    // phase
    var imagePath: String = ""
    var systemImageSelection: SystemImageSelection = .latestMacOS
    var hasChosenSystem = false

    // macOS 27 first-boot provisioning. The password lives only in this
    // in-memory form and is moved to Keychain after the VM is installed.
    var provisionsMacGuest = false
    var provisioningFullName = "EZVM User"
    var provisioningUsername = "ezvm"
    var provisioningPassword = ""
    var provisioningPasswordConfirmation = ""
    var provisioningAutomaticLogin = false
    var provisioningRemoteLogin = false

    var logs: [LogModel] = []

    var installingProgress: Double = 0.0

    var disablePreviousButton = false

    // creating phase status
    var isCreating = false
    var canCancelCreation = false
    var creationCancellationKind: VMCreationCancellationKind?
    var statusText: String = ""
    var creationStage: String = "Preparing"


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
