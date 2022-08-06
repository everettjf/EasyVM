//
//  FileSelectTextField.swift
//  EasyVM
//
//  Created by everettjf on 2022/8/6.
//

import SwiftUI

struct FileSelectTextField: View {
    let name: String
    
    @State private var filePath: String = ""
    
    var body: some View {
        HStack {
            TextField(name, text: $filePath)
            Button {
                
            } label: {
                Image(systemName: "doc.badge.plus")
            }
            
            Button {
                
            } label: {
                Image(systemName: "icloud.and.arrow.down")
            }


        }
    }
}

struct FileSelectTextField_Previews: PreviewProvider {
    static var previews: some View {
        FileSelectTextField(name: "File Path")
    }
}
