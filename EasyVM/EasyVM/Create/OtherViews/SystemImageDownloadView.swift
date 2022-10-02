//
//  SystemImageDownloadView.swift
//  EasyVM
//
//  Created by everettjf on 2022/9/15.
//

import SwiftUI


class SystemImageDownloadViewState : ObservableObject {
    
    enum ImageSource {
        case latest_avaliable, input_url
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
    
    private var downloader: (any VMOSImageDownloader)?
    
    func cancelDownload() {
        self.downloader?.cancelDownload()
        self.downloader = nil
    }
    
    func startDownload(vmOSType: VMOSType, localPath: URL) {
        
        downloadStatus = .downloading
        
        self.downloader = VMOSImageDownloadFactory.getDownloader(vmOSType)
        if downloadMethod == .latest_avaliable {
            downloader?.downloadLatest(toLocalPath: localPath) { result in
                
                if case let .failure(error) = result {
                    self.downloadStatus = .downloadFailed
                    self.downloadMessage = error
                } else {
                    self.downloadStatus = .downloadSuccess
                }
                
            } downloadProgressHandler: { percent in
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
        } else {
            guard let imageURL = URL(string: downloadInputUrl) else {
                downloadStatus = .initial
                return
            }
            downloader?.downloadURL(imageURL: imageURL, toLocalPath: localPath) { result in
                
                if case let .failure(error) = result {
                    self.downloadStatus = .downloadFailed
                    self.downloadMessage = error
                } else {
                    self.downloadStatus = .downloadSuccess
                }
                
            } downloadProgressHandler: { percent in
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
            return "Download failed"
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
    @EnvironmentObject var formData: CreateFormStateObject
    @EnvironmentObject var configData: VMConfigurationViewStateObject
    @ObservedObject var state = SystemImageDownloadViewState()
    
    var body: some View {
        
        VStack {
            HStack {
                Text("Download System Image")
                    .fontWeight(.bold)
            }
            Spacer()
            
            Picker("Source of system image", selection: $state.downloadMethod) {
                Text("Latest available image").tag(SystemImageDownloadViewState.ImageSource.latest_avaliable)
                Text("System image url").tag(SystemImageDownloadViewState.ImageSource.input_url)
            }
            .pickerStyle(.menu)
            
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
        .frame(width: 600, height:260)
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
