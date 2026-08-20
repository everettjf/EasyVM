//
//  SystemImageDownloadView.swift
//  EasyVM
//
//  Created by everettjf on 2022/9/15.
//

import SwiftUI


#if arch(arm64)
class SystemImageDownloadViewState : ObservableObject {

    enum ImageSource: Hashable, Identifiable {
        case latestAvailable
        case catalog(VMSystemImageCatalogItem)
        case inputURL

        var id: String {
            switch self {
            case .latestAvailable:
                return "latest-available"
            case .catalog(let item):
                return "catalog-\(item.id)"
            case .inputURL:
                return "input-url"
            }
        }
    }

    enum DownloadStatus {
        case initial, downloading, downloadSuccess, downloadFailed
    }


    @Published var stateMessage: String = ""
    @Published var current: Double = 0

    @Published var downloadMethod: ImageSource = .latestAvailable
    @Published var downloadInputUrl: String = ""

    @Published var downloadStatus: DownloadStatus = .initial
    @Published var downloadMessage: String = ""

    private var downloader: (any VMOSDownloader)?

    func setupDefaultMethod(vmOSType: VMOSType) {
        switch vmOSType {
        case .macOS:
            downloadMethod = .latestAvailable
        case .linux:
            if let firstItem = VMSystemImageCatalog.items(for: .linux).first {
                downloadMethod = .catalog(firstItem)
            } else {
                downloadMethod = .inputURL
            }
        }
    }

    func cancelDownload() {
        self.downloader?.cancelDownload()
        self.downloader = nil
    }

    func startDownload(vmOSType: VMOSType, localPath: URL) {

        let progressHandler: (Double) -> Void = { percent in
            var value = percent * 100
            if value < 0 {
                value = 0
            }
            if value > 100 {
                value = 100
            }
            DispatchQueue.main.async {
                self.current = value
            }
        }
        let completionHandler: (VMOSResultVoid) -> Void = { result in
            DispatchQueue.main.async {
                if case let .failure(error) = result {
                    self.downloadStatus = .downloadFailed
                    self.downloadMessage = error
                } else {
                    self.downloadStatus = .downloadSuccess
                }
            }
        }

        self.downloader = VMOSDownloaderFactory.getDownloader(vmOSType)

        switch downloadMethod {
        case .latestAvailable:
            downloadStatus = .downloading
            downloader?.downloadLatest(toLocalPath: localPath, completionHandler: completionHandler, downloadProgressHandler: progressHandler)
        case .catalog(let item):
            downloadStatus = .downloading
            downloader?.downloadURL(imageURL: item.url, toLocalPath: localPath, completionHandler: completionHandler, downloadProgressHandler: progressHandler)
        case .inputURL:
            guard let imageURL = URL(string: downloadInputUrl) else {
                downloadStatus = .initial
                downloadMessage = "Invalid image URL"
                return
            }
            downloadStatus = .downloading
            downloader?.downloadURL(imageURL: imageURL, toLocalPath: localPath, completionHandler: completionHandler, downloadProgressHandler: progressHandler)
        }
    }

    func getDownloadButtonText() -> String {
        switch downloadStatus {
        case .initial:
            return "Start Download"
        case .downloading:
            return "Downloading"
        case .downloadSuccess:
            return "Confirm, use the downloaded image"
        case .downloadFailed:
            return "Retry Download"
        }
    }


    func getDownloadStatusText() -> String {
        switch downloadStatus {
        case .initial:
            return ""
        case .downloading:
            return "Downloading"
        case .downloadSuccess:
            return "Download success"
        case .downloadFailed:
            return "Download failed"
        }
    }
}


struct DownloadButtonView : View {
    let name: String
    let image: String

    @State private var borderColor: Color = .gray
    var body: some View {
        HStack {
            Image(systemName: image)
            Text(name)
        }
        .padding(.all, 5)
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .stroke(.gray, lineWidth: 1)
        )
        .onHover { hover in
            if hover {
                borderColor = .blue
            } else {
                borderColor = .gray
            }
        }
    }
}

struct SystemImageDownloadView: View {

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var formData: VMCreateViewStateObject
    @EnvironmentObject private var configData: VMConfigurationViewStateObject
    @StateObject private var state: SystemImageDownloadViewState

    init(initialSource: SystemImageDownloadViewState.ImageSource? = nil) {
        let state = SystemImageDownloadViewState()
        if let initialSource {
            state.downloadMethod = initialSource
        }
        _state = StateObject(wrappedValue: state)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text(configData.osType == .macOS ? "Download macOS Restore Image" : "Download Linux Install Image")
                    .font(.title3.weight(.semibold))
                Text("The image will be saved and reused for future virtual machines.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            GroupBox {
                HStack(spacing: 12) {
                    Image(systemName: configData.osType == .macOS ? "apple.logo" : "opticaldiscdrive")
                        .font(.title2)
                        .foregroundStyle(configData.osType == .macOS ? Color.blue : Color.orange)
                        .frame(width: 32)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(sourceTitle)
                            .font(.headline)
                        Text(sourceDetail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let sourceURL {
                            Text(sourceURL.absoluteString)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .lineLimit(2)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                        }
                    }
                    Spacer()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("download-image-summary")

            if state.downloadMethod == .inputURL {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Image URL")
                        .font(.caption.weight(.semibold))
                    TextField("https://example.com/image.iso", text: $state.downloadInputUrl)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("custom-image-url")
                }
            }

            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text(state.getDownloadStatusText())
                    Spacer()
                    Text("\(String(format: "%.1f", state.current))%")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                ProgressView(value: state.current, total: 100)
                if !state.downloadMessage.isEmpty {
                    Text(state.downloadMessage)
                        .font(.caption)
                        .foregroundStyle(state.downloadStatus == .downloadFailed ? Color.red : Color.secondary)
                }
            }

            Spacer(minLength: 0)

            HStack {
                Button {
                    state.cancelDownload()
                    dismiss()
                } label: {
                    Text("Cancel")
                }

                Spacer()

                Button {
                    startDownload()
                } label: {
                    Text(state.getDownloadButtonText())
                }
                .disabled(state.downloadStatus == .downloading)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("download-system-image")
            }
        }
        .padding()
        .frame(width: 620, height: 360)
    }

    private var sourceTitle: String {
        switch state.downloadMethod {
        case .latestAvailable:
            return "Latest compatible macOS"
        case .catalog(let item):
            return item.name
        case .inputURL:
            return "Custom image URL"
        }
    }

    private var sourceDetail: String {
        switch state.downloadMethod {
        case .latestAvailable:
            return "Apple will provide the newest restore image supported by this Mac."
        case .catalog(let item):
            return item.detail
        case .inputURL:
            return configData.osType == .macOS ? "Enter a direct IPSW download URL." : "Enter a direct ARM64 ISO download URL."
        }
    }

    private var sourceURL: URL? {
        if case .catalog(let item) = state.downloadMethod {
            return item.url
        }
        return nil
    }

    func targetFileName() -> String {
        let defaultExtension = configData.osType == .macOS ? "ipsw" : "iso"
        switch state.downloadMethod {
        case .latestAvailable:
            return "macOS-Latest.ipsw"
        case .catalog(let item):
            let ext = item.url.pathExtension.isEmpty ? defaultExtension : item.url.pathExtension
            return "\(item.id).\(ext)"
        case .inputURL:
            if let url = URL(string: state.downloadInputUrl) {
                let fileName = url.lastPathComponent
                if !fileName.isEmpty && fileName != "/" && fileName != "." {
                    return fileName
                }
            }
            return "CustomImage.\(defaultExtension)"
        }
    }

    func startDownload() {
        guard let localPath = VMImageStore.preparePath(fileName: targetFileName()) else {
            state.downloadMessage = "Unable to create the image store directory"
            return
        }

        if state.downloadStatus == .initial || state.downloadStatus == .downloadFailed {
            // an image downloaded before can be reused directly
            if FileManager.default.fileExists(atPath: localPath.path(percentEncoded: false)) {
                formData.imagePath = localPath.path(percentEncoded: false)
                dismiss()
                return
            }
            state.startDownload(vmOSType: configData.osType, localPath: localPath)
        }

        if state.downloadStatus == .downloadSuccess {
            formData.imagePath = localPath.path(percentEncoded: false)
            dismiss()
        }
    }
}

struct SystemImageDownloadView_Previews: PreviewProvider {
    static var previews: some View {
        SystemImageDownloadView()
    }
}


#endif
