//
//  SystemImageDownloadView.swift
//  EasyVM
//
//  Created by everettjf on 2022/9/15.
//

import SwiftUI


#if arch(arm64)
class SystemImageDownloadViewState : ObservableObject {

    enum ImageSource : Hashable {
        case latest_avaliable
        case catalog(VMSystemImageCatalogItem)
        case input_url
    }

    enum DownloadStatus {
        case initial, downloading, downloadSuccess, downloadFailed
    }


    @Published var stateMessage: String = ""
    @Published var current: Double = 0

    @Published var downloadMethod: ImageSource = .latest_avaliable
    @Published var downloadInputUrl: String = ""

    @Published var downloadStatus: DownloadStatus = .initial
    @Published var downloadMessage: String = ""

    private var downloader: (any VMOSDownloader)?

    func setupDefaultMethod(vmOSType: VMOSType) {
        switch vmOSType {
        case .macOS:
            downloadMethod = .latest_avaliable
        case .linux:
            if let firstItem = VMSystemImageCatalog.items(for: .linux).first {
                downloadMethod = .catalog(firstItem)
            } else {
                downloadMethod = .input_url
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
        case .latest_avaliable:
            downloadStatus = .downloading
            downloader?.downloadLatest(toLocalPath: localPath, completionHandler: completionHandler, downloadProgressHandler: progressHandler)
        case .catalog(let item):
            downloadStatus = .downloading
            downloader?.downloadURL(imageURL: item.url, toLocalPath: localPath, completionHandler: completionHandler, downloadProgressHandler: progressHandler)
        case .input_url:
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

    @Environment(\.presentationMode) var presentationMode
    @EnvironmentObject var formData: VMCreateViewStateObject
    @EnvironmentObject var configData: VMConfigurationViewStateObject
    @StateObject private var state = SystemImageDownloadViewState()

    var body: some View {

        VStack {
            HStack {
                Text(configData.osType == .macOS ? "Download macOS Restore Image" : "Download Linux Install Image")
                    .fontWeight(.bold)
            }
            Spacer()

            Picker(configData.osType == .macOS ? "macOS version" : "Linux distribution", selection: $state.downloadMethod) {
                if configData.osType == .macOS {
                    Text("Latest available image").tag(SystemImageDownloadViewState.ImageSource.latest_avaliable)
                }
                ForEach(VMSystemImageCatalog.items(for: configData.osType)) { item in
                    Text("\(item.name) (\(item.detail))").tag(SystemImageDownloadViewState.ImageSource.catalog(item))
                }
                Text("Custom image url").tag(SystemImageDownloadViewState.ImageSource.input_url)
            }
            .pickerStyle(.menu)

            if case .catalog(let item) = state.downloadMethod {
                HStack {
                    Text(item.url.absoluteString)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .textSelection(.enabled)
                    Spacer()
                }
            }

            if state.downloadMethod == .input_url {
                HStack {
                    Text("Image URL:")
                    TextField("Image URL", text: $state.downloadInputUrl)
                        .lineLimit(4)
                        .textFieldStyle(.plain)
                }
            }


            Spacer()

            HStack {
                Text(state.getDownloadStatusText())
                    .font(.caption)
                Spacer()
            }

            HStack {
                Text(state.downloadMessage)
                    .font(.caption)
                Spacer()
            }
            HStack {
                Text("\(String(format: "%.2f", state.current))%")
                    .font(.caption)
                ProgressView(value: state.current, total: 100)
            }

            Spacer()

            HStack {
                Button {
                    state.cancelDownload()
                    presentationMode.wrappedValue.dismiss()
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
            }
        }
        .padding()
        .frame(width: 600, height:300)
        .onAppear {
            state.setupDefaultMethod(vmOSType: configData.osType)
        }
    }

    func startDownload() {
        guard let localPath = formData.getSystemImagePathForDownload(osType: configData.osType) else {
            return
        }

        if state.downloadStatus == .initial || state.downloadStatus == .downloadFailed {
            state.startDownload(vmOSType: configData.osType, localPath: localPath)
        }

        if state.downloadStatus == .downloadSuccess {
            formData.imagePath = localPath.path(percentEncoded: false)
            presentationMode.wrappedValue.dismiss()
        }
    }
}

struct SystemImageDownloadView_Previews: PreviewProvider {
    static var previews: some View {
        SystemImageDownloadView()
    }
}


#endif
