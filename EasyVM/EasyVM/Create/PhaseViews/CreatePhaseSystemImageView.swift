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
                .font(.system(size: 70))
                .frame(width:100,height: 120)
            
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


class CreatePhaseSystemImageViewHandler: CreateStepperGuidePhaseHandler {
    func verifyForm(formData: CreateFormModel) -> CreateStepperGuidePhaseVerifyResult {
        return .success
    }
}


struct CreatePhaseSystemImageView: View {
    @EnvironmentObject var formData: CreateFormModel
    
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
                SystemImageSourceTypeView(image: "opticaldiscdrive", name: "From local file system")
                    .onTapGesture {
                        selectFromFileSystem()
                    }
                SystemImageSourceTypeView(image: "cloud", name: "Download from network")
                    .onTapGesture {
                        selectFromNetwork()
                    }
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
            
            if let path = path {
                self.formData.imagePath = path.absoluteString
            }
        }
    }
    
    func selectFromNetwork() {
        isShowDownload.toggle()
    }
}

struct CreatePhaseSystemImage_Previews: PreviewProvider {
    static var previews: some View {
        let formData = CreateFormModel()
        CreatePhaseSystemImageView()
            .frame(width: 600, height:400)
            .environmentObject(formData)
    }
}
