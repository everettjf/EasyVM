//
//  CreatePhaseChooseSystemImage.swift
//  EasyVM
//
//  Created by everettjf on 2022/9/12.
//

import SwiftUI


struct SystemImageSourceTypeView: View {
    let image: String
    let name: String
    
    @State private var borderColor: Color = .gray
    
    var body: some View {
        VStack {
            Image(systemName: image)
                .font(.system(size: 50))
                .frame(width:70,height: 70)
            
            Text(name)
        }
        .padding()
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .stroke(borderColor, lineWidth: 1)
        )
        .shadow(radius: 16)
        .onHover { hover in
            if hover {
                borderColor = .blue
            } else {
                borderColor = .gray
            }
        }
    }
}


class CreatePhaseSystemImageViewHandler: VMCreateStepperGuidePhaseHandler {
    func verifyForm(context: VMCreateStepperGuidePhaseContext) -> VMOSResultVoid {
        if context.formData.imagePath.isEmpty {
            return .failure("Please select system image")
        }
        return .success
    }
    func onStepMovedIn(context: VMCreateStepperGuidePhaseContext) async -> VMOSResultVoid {
        return .success
    }
}


struct CreatePhaseSystemImageView: View {
    @EnvironmentObject var formData: VMCreateViewStateObject
    @EnvironmentObject var configData: VMConfigurationViewStateObject
    
    @State var isShowDownload: Bool = false
    
    var body: some View {
        content
            .sheet(isPresented: $isShowDownload, content: {
                SystemImageDownloadView()
            })

    }
    
    var content: some View {
        VStack {
            
            Text("Select System Image: ")
                .font(.title3)
                .padding(.all)
            
            Spacer()
            
            
            HStack {
                Spacer()
                SystemImageSourceTypeView(image: "opticaldiscdrive", name: "From local file system")
                    .onTapGesture {
                        selectFromFileSystem()
                    }
                
                if configData.osType == .macOS {
                    SystemImageSourceTypeView(image: "cloud", name: "Download from network")
                        .onTapGesture {
                            selectFromNetwork()
                        }
                }
                
                Spacer()
            }
            
            Form {
                VStack(alignment: .leading) {
                    HStack {
                        Text("System Image Path:")
                        Spacer()
                        Text(formData.imagePath)
                            .lineLimit(4)
                    }
                }
            }
            .formStyle(.grouped)
            
            Spacer()
        }
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
    
    func selectFromNetwork() {
        isShowDownload.toggle()
    }
}

struct CreatePhaseSystemImage_Previews: PreviewProvider {
    
    static let formData = VMCreateViewStateObject()
    static let configData = VMConfigurationViewStateObject()
    
    static var previews: some View {
        
        CreatePhaseSystemImageView()
            .frame(width: 600, height:400)
            .environmentObject(formData)
            .environmentObject(configData)
    }
}
