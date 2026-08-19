//
//  CreatePhaseSystemView.swift
//  EasyVM
//
//  Created by everettjf on 2026/8/18.
//

import SwiftUI

#if arch(arm64)

struct SystemCardView: View {
    let image: String
    let name: String
    let selected: Bool

    @State private var borderColor: Color = .gray

    var body: some View {
        VStack {
            Image(systemName: image)
                .font(.system(size: 40))
                .frame(width: 70, height: 60)

            Text(name)
        }
        .padding()
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .stroke(selected ? .blue : borderColor, lineWidth: selected ? 3 : 1)
        )
        .shadow(radius: 8)
        .onHover { hover in
            if hover {
                borderColor = .blue
            } else {
                borderColor = .gray
            }
        }
    }
}

struct SystemImageSourceTypeView: View {
    let image: String
    let name: String

    @State private var borderColor: Color = .gray

    var body: some View {
        VStack {
            Image(systemName: image)
                .font(.system(size: 30))
                .frame(width: 50, height: 40)

            Text(name)
        }
        .padding()
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .stroke(borderColor, lineWidth: 1)
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


class CreatePhaseSystemViewHandler: VMCreateStepperGuidePhaseHandler {
    func verifyForm(context: VMCreateStepperGuidePhaseContext) -> VMOSResultVoid {
        if context.formData.imagePath.isEmpty {
            return .failure("Please choose a system version to download, or pick a local ipsw/iso file")
        }
        if !FileManager.default.fileExists(atPath: context.formData.imagePath) {
            return .failure("System image file does not exist : \(context.formData.imagePath)")
        }
        return .success
    }
    func onStepMovedIn(context: VMCreateStepperGuidePhaseContext) async -> VMOSResultVoid {
        return .success
    }
}


struct CreatePhaseSystemView: View {
    @EnvironmentObject var formData: VMCreateViewStateObject
    @EnvironmentObject var configData: VMConfigurationViewStateObject

    @State private var isShowDownload = false

    var body: some View {
        content
            .sheet(isPresented: $isShowDownload, content: {
                SystemImageDownloadView()
            })
    }

    var content: some View {
        VStack {
            Text("Choose the operating system :")
                .font(.title3)
                .padding(.top)

            HStack(spacing: 30) {
                SystemCardView(image: "macpro.gen3", name: "macOS", selected: configData.osType == .macOS)
                    .onTapGesture {
                        switchOSType(.macOS)
                    }
                SystemCardView(image: "pc", name: "Linux", selected: configData.osType == .linux)
                    .onTapGesture {
                        switchOSType(.linux)
                    }
            }
            .padding(.bottom)

            Text(configData.osType == .macOS ? "Choose a macOS restore image :" : "Choose a Linux install image (ARM64) :")
                .font(.title3)

            HStack(spacing: 20) {
                SystemImageSourceTypeView(image: "cloud", name: configData.osType == .macOS ? "Choose macOS version" : "Choose Linux distribution")
                    .onTapGesture {
                        isShowDownload.toggle()
                    }

                SystemImageSourceTypeView(image: "opticaldiscdrive", name: "From local file system")
                    .onTapGesture {
                        selectFromFileSystem()
                    }
            }

            Form {
                VStack(alignment: .leading) {
                    HStack {
                        Text("System Image :")
                        Spacer()
                        if formData.imagePath.isEmpty {
                            Text("Not selected yet")
                                .foregroundStyle(.secondary)
                        } else {
                            Text(formData.imagePath)
                                .lineLimit(4)
                        }
                    }
                }
            }
            .formStyle(.grouped)

            Spacer()
        }
    }

    func switchOSType(_ osType: VMOSType) {
        if configData.osType == osType {
            return
        }
        configData.osType = osType
        // devices and defaults differ between systems, so previously chosen
        // configuration and image no longer apply
        configData.resetDefaultConfig()
        formData.imagePath = ""
    }

    func selectFromFileSystem() {
        MacKitUtil.selectFile(title: "Choose system image file(.ipsw/.iso)") { path in
            print("choose : \(String(describing: path))")
            guard let path = path else {
                return
            }

            self.formData.imagePath = path.path(percentEncoded: false)
        }
    }
}

struct CreatePhaseSystemView_Previews: PreviewProvider {
    static let formData = VMCreateViewStateObject()
    static let configData = VMConfigurationViewStateObject()

    static var previews: some View {
        CreatePhaseSystemView()
            .frame(width: 600, height: 500)
            .environmentObject(formData)
            .environmentObject(configData)
    }
}

#endif
