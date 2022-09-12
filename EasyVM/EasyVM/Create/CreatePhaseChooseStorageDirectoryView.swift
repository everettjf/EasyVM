//
//  CreatePhaseChooseStorageDirectoryView.swift
//  EasyVM
//
//  Created by everettjf on 2022/9/12.
//

import SwiftUI

struct CreatePhaseChooseStorageDirectoryView: View {
    var body: some View {
        
            VStack {
                
                Text("Choose the location for virtual machine:")
                    .font(.title3)
                    .padding(.all)
                
                Form {
                    Section {
                        LabeledContent("Location") {
                            HStack {
                                Text("/Users/everettjf/EasyVirtualMachines")
                                Button {
                                    
                                } label: {
                                    Image(systemName: "folder.badge.plus")
                                }
                            }
                        }
                    }
                }
                .formStyle(.grouped)
            }
    }
}

struct CreatePhaseChooseStorageDirectoryView_Previews: PreviewProvider {
    static var previews: some View {
        CreatePhaseChooseStorageDirectoryView()
    }
}
