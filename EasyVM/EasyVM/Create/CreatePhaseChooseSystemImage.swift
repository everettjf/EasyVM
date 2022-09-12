//
//  CreatePhaseChooseSystemImage.swift
//  EasyVM
//
//  Created by everettjf on 2022/9/12.
//

import SwiftUI

struct CreatePhaseChooseSystemImage: View {
    var body: some View {
        VStack {
            
            Text("Choose one of the method below : ")
                .font(.title3)
                .padding(.all)
            
            Form {
                Section("Method 1 : Choose System Image From Disk") {
                    LabeledContent("Image Path") {
                        HStack {
                            Text("/Users/everettjf/Download/macos-latest.ipsw")
                            Button {
                                
                            } label: {
                                Image(systemName: "doc.badge.plus")
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
                            Button("Download") {
                                
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
