//
//  CreatePhaseChooseStorageDirectoryView.swift
//  EasyVM
//
//  Created by everettjf on 2022/9/12.
//

import SwiftUI

struct CreatePhaseSaveDirectoryView: View {
    
    @State private var saveDirectory: String = ""
    
    var body: some View {
        
        VStack {
            Text("Choose the location for virtual machine:")
                .font(.title3)
                .padding(.all)
            
            Form {
                
                Section("Location") {
                    VStack(alignment: .leading) {
                        HStack {
                            Text("Select where machine files save :")
                            Spacer()
                            Text(saveDirectory)
                                .lineLimit(4)
                        }
                        
                        HStack {
                            Spacer()
                            Button {
                                MacKitUtil.selectDirectory(title: "Select a direcotry") { path in
                                    print("directory = \(String(describing: path))")
                                    if let path = path {
                                        self.saveDirectory = path.absoluteString
                                    }
                                }
                            } label: {
                                Image(systemName: "folder.badge.plus")
                                Text("Select")
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
        }
    }
}

struct CreatePhaseSaveDirectoryView_Previews: PreviewProvider {
    static var previews: some View {
        CreatePhaseSaveDirectoryView()
    }
}