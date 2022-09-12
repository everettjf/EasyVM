//
//  CreatePhaseChooseSystemImage.swift
//  EasyVM
//
//  Created by everettjf on 2022/9/12.
//

import SwiftUI

struct CreatePhaseChooseSystemImage: View {
    @State var imagePath: String = ""
    
    
    var body: some View {
        VStack {
            
            Text("Choose one of the method below : ")
                .font(.title3)
                .padding(.all)
            
            Form {
                Section("Method 1 : Select System Image From Disk") {
                    VStack(alignment: .leading) {
                        HStack {
                            Text("System Image Path:")
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
                
                Section("Method 2 : Download System Image From Apple Server") {
                    
                    VStack(alignment: .leading) {
                        ProgressView(value: 250, total: 1000)
                        
                        Text("25% - 250MB / 1000GB").font(.caption)
                        
                        HStack {
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

struct CreatePhaseChooseSystemImage_Previews: PreviewProvider {
    static var previews: some View {
        CreatePhaseChooseSystemImage()
            .frame(width: 600, height:400)
    }
}
