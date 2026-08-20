//
//  CreatePhaseCreatingView.swift
//  EasyVM
//
//  Created by everettjf on 2022/9/12.
//

import SwiftUI

#if arch(arm64)

class CreatePhaseCreatingViewHandler: VMCreateStepperGuidePhaseHandler {
    private var downloader: (any VMOSDownloader)?

    func verifyForm(context: VMCreateStepperGuidePhaseContext) -> VMOSResultVoid {
        return .success
    }

    func cancel(context: VMCreateStepperGuidePhaseContext) {
        guard context.formData.canCancelCreation else { return }
        context.formData.canCancelCreation = false
        downloader?.cancelDownload()
        downloader = nil
    }

    func onStepMovedIn(context: VMCreateStepperGuidePhaseContext) async -> VMOSResultVoid {
        context.formData.logs = []
        context.formData.installingProgress = 0
        context.formData.creationStage = "Preparing"
        context.formData.isCreating = true
        context.formData.canCancelCreation = false

        let imageResult = await resolveSystemImage(context: context)
        guard case .success(let imageURL) = imageResult else {
            context.formData.isCreating = false
            if case .failure(let error) = imageResult {
                context.formData.creationStage = "Couldn’t download the system image"
                context.formData.addLog("❌ \(error)")
                return .failure(error)
            }
            return .failure("Unable to resolve the system image")
        }
        context.formData.imagePath = imageURL.path(percentEncoded: false)

        if context.configData.osType == .linux {
            attachLinuxInstaller(imagePath: context.formData.imagePath, context: context)
        }

        // fill from form
        let rootPath = URL(filePath:context.formData.rootPath)
        let imagePath = imageURL
        print("root path : \(rootPath)")
        print("image path : \(imagePath)")

        let stateModel = VMStateModel(imagePath: imagePath)
        let configModel = context.configData.getConfigModel()
        let vmModel = VMModel(rootPath: rootPath, state: stateModel, config: configModel)

        // create vm from vmmodel
        print("!! Start create virtual machine")
        context.formData.creationStage = context.configData.osType == .macOS ? "Installing macOS" : "Creating virtual machine"
        context.formData.addLog("System image is ready")
        let creator = VMOSCreateFactory.getCreator(configModel.type)
        let result = await creator.create(model: vmModel, progress: { progressInfo in
            switch progressInfo {
            case .info(let log):
                print("LOG INFO : \(log)")
                context.formData.addLog(log)
            case .error(let log):
                print("LOG ERROR : \(log)")
                context.formData.addLog("❌ ERROR : \(log)")
            case .progress(let percent):
                print("Progress : \(percent)")
                context.formData.changeProgress(0.35 + (percent * 0.65))
            }
        })
        print("!! End create virtual machine")
        context.formData.isCreating = false

        switch result {
        case .failure(let error):
            context.formData.creationStage = "Creation failed"
            print("Failed to create : \(error)")
        case .success:
            context.formData.creationStage = "Ready"
            context.formData.changeProgress(1)
            context.formData.disablePreviousButton = true
            sharedAppConfigManager.addVMPathWithRefresh(url: rootPath)
        }

        return result
    }

    private func resolveSystemImage(context: VMCreateStepperGuidePhaseContext) async -> VMOSResult<URL, String> {
        switch context.formData.systemImageSelection {
        case .localFile(let url):
            guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
                return .failure("The selected image no longer exists: \(url.path(percentEncoded: false))")
            }
            context.formData.creationStage = "Using local system image"
            context.formData.changeProgress(0.35)
            return .success(url)

        case .latestMacOS:
            guard let target = VMImageStore.preparePath(fileName: "macOS-Latest.ipsw") else {
                return .failure("Unable to prepare the system image cache")
            }
            if FileManager.default.fileExists(atPath: target.path(percentEncoded: false)) {
                context.formData.creationStage = "Using cached macOS image"
                context.formData.changeProgress(0.35)
                return .success(target)
            }
            return await downloadImage(osType: .macOS, target: target, remoteURL: nil, context: context)

        case .catalog(let item):
            let fallbackExtension = item.osType == .macOS ? "ipsw" : "iso"
            let ext = item.url.pathExtension.isEmpty ? fallbackExtension : item.url.pathExtension
            guard let target = VMImageStore.preparePath(fileName: "\(item.id).\(ext)") else {
                return .failure("Unable to prepare the system image cache")
            }
            if FileManager.default.fileExists(atPath: target.path(percentEncoded: false)) {
                context.formData.creationStage = "Using cached system image"
                context.formData.changeProgress(0.35)
                return .success(target)
            }
            return await downloadImage(osType: item.osType, target: target, remoteURL: item.url, context: context)

        case .remoteURL(let url):
            let fallbackExtension = context.configData.osType == .macOS ? "ipsw" : "iso"
            let fileName = url.lastPathComponent.isEmpty ? "CustomImage.\(fallbackExtension)" : url.lastPathComponent
            guard let target = VMImageStore.preparePath(fileName: fileName) else {
                return .failure("Unable to prepare the system image cache")
            }
            if FileManager.default.fileExists(atPath: target.path(percentEncoded: false)) {
                context.formData.creationStage = "Using cached system image"
                context.formData.changeProgress(0.35)
                return .success(target)
            }
            return await downloadImage(osType: context.configData.osType, target: target, remoteURL: url, context: context)
        }
    }

    private func downloadImage(
        osType: VMOSType,
        target: URL,
        remoteURL: URL?,
        context: VMCreateStepperGuidePhaseContext
    ) async -> VMOSResult<URL, String> {
        context.formData.creationStage = "Downloading system image"
        context.formData.addLog("Downloading \(context.formData.systemImageSelection.title)")
        let activeDownloader = VMOSDownloaderFactory.getDownloader(osType)
        downloader = activeDownloader
        context.formData.canCancelCreation = true

        let result: VMOSResultVoid = await withCheckedContinuation { continuation in
            let completion: (VMOSResultVoid) -> Void = { result in
                continuation.resume(returning: result)
            }
            let progress: (Double) -> Void = { fraction in
                Task { @MainActor in
                    context.formData.changeProgress(max(0, min(1, fraction)) * 0.35)
                }
            }

            if let remoteURL {
                activeDownloader.downloadURL(
                    imageURL: remoteURL,
                    toLocalPath: target,
                    completionHandler: completion,
                    downloadProgressHandler: progress
                )
            } else {
                activeDownloader.downloadLatest(
                    toLocalPath: target,
                    completionHandler: completion,
                    downloadProgressHandler: progress
                )
            }
        }
        context.formData.canCancelCreation = false
        downloader = nil

        switch result {
        case .success:
            context.formData.changeProgress(0.35)
            return .success(target)
        case .failure(let error):
            return .failure(error)
        }
    }

    private func attachLinuxInstaller(imagePath: String, context: VMCreateStepperGuidePhaseContext) {
        context.configData.storageDevices.removeAll {
            $0.data.type == .USB && ($0.data.imagePath.isEmpty || $0.data.imagePath == context.formData.imagePath)
        }
        context.configData.storageDevices.append(
            VMModelFieldStorageDeviceItemModel(
                data: VMModelFieldStorageDevice(type: .USB, size: 0, imagePath: imagePath)
            )
        )
    }
}


struct CreatePhaseCreatingView: View {
    @EnvironmentObject var formData: VMCreateViewStateObject

    @State private var showDetails = false

    var body: some View {
        VStack {
            Image(systemName: formData.creationStage == "Ready" ? "checkmark.circle.fill" : "shippingbox.and.arrow.backward")
                .font(.system(size: 42))
                .foregroundStyle(formData.creationStage == "Ready" ? Color.green : Color.accentColor)

            Text(formData.creationStage)
                .font(.title2.weight(.semibold))

            Text("EasyVM will download the selected image if needed, then create and install your virtual machine. You can leave this window open and wait once.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 560)

            // current activity headline, so the user does not have to read logs
            HStack(spacing: 12) {
                if formData.isCreating {
                    ProgressView()
                        .controlSize(.small)
                }
                Text(formData.statusText)
                    .lineLimit(2)
                Spacer()
            }

            HStack(spacing: 12) {
                Text("\(String(format: "%.0f", 100 * formData.installingProgress))%")
                    .font(.caption)
                ProgressView(value: 100 * formData.installingProgress, total: 100)
            }

            DisclosureGroup("Installation details", isExpanded: $showDetails) {
                List {
                    ForEach(formData.logs) { item in
                        HStack {
                            Text(item.time)
                                .foregroundStyle(.secondary)
                            Text(item.log)
                                .lineLimit(0)
                                .multilineTextAlignment(.leading)
                        }
                        .font(.caption)
                    }
                }
                .frame(minHeight: 180)
            }

            Spacer()
        }
        .padding(24)
        .onChange(of: formData.statusText) { newValue in
            // surface the full log as soon as something goes wrong
            if newValue.hasPrefix("❌") {
                showDetails = true
            }
        }
    }
}

struct CreatePhaseCreatingView_Previews: PreviewProvider {
    static var previews: some View {
        let formData = VMCreateViewStateObject()
        CreatePhaseCreatingView()
            .environmentObject(formData)
    }
}


#endif
