//
//  CreatePhaseChooseSystemImage.swift
//  EasyVM
//
//  Created by everettjf on 2022/9/12.
//

import SwiftUI

struct CreatePhaseSystemImageView: View {
    enum ImageSource {
        case latest_avaliable, input_url
    }
    
    
    @State var imagePath: String = ""
    @State var downloadMethod: ImageSource = .latest_avaliable
    @State var downloadInputUrl: String = ""
    
    var body: some View {
        VStack {
            
            Text("Select System Image: ")
                .font(.title3)
                .padding(.all)
            
            Form {
                Section("Select system image from file system") {
                    VStack(alignment: .leading) {
                        HStack {
                            Text("System image path:")
                            Spacer()
                            Text(imagePath)
                                .lineLimit(4)
                        }
                        HStack {
                            Spacer()
                            Button {
                                MacKitUtil.selectFile(title: "Choose system image file(.ipsw/.iso)") { path in
                                    print("choose : \(String(describing: path))")
                                    
                                    if let path = path {
                                        imagePath = path.absoluteString
                                    }
                                }
                            } label: {
                                Image(systemName: "doc.badge.plus")
                                Text("Select")
                            }
                        }
                    }
                }
                
                Section("Or you can download system image directly from apple server") {
                    
                    VStack {
                        
                        Picker("Image Source", selection: $downloadMethod) {
                            Text("Latest Avaliable Image").tag(ImageSource.latest_avaliable)
                            Text("Image URL Input Below").tag(ImageSource.input_url)
                        }
                        .pickerStyle(.menu)
                        
                        if downloadMethod == .input_url {
                            TextField("Image URL", text: $downloadInputUrl)
                                .multilineTextAlignment(.trailing)
                                .textFieldStyle(.plain)
                        }
                        ProgressView(value: 250, total: 1000)
                        
                        HStack {
                            Text("25% - 250MB / 1000GB").font(.caption)
                            Spacer()
                            Button {
                                
                            } label: {
                                Image(systemName: "icloud.and.arrow.down")
                                Text("Download")
                            }

                        }
                    }
                }
            }
            .formStyle(.grouped)
        }
    }
}

struct CreatePhaseSystemImage_Previews: PreviewProvider {
    static var previews: some View {
        CreatePhaseSystemImageView()
            .frame(width: 600, height:400)
    }
}
