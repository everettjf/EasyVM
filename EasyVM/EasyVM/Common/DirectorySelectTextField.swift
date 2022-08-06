//
//  DirectorySelectTextField.swift
//  EasyVM
//
//  Created by everettjf on 2022/8/6.
//

import SwiftUI

struct DirectorySelectTextField: View {
    let name: String
    
    @State private var pathString: String = ""
    
    var body: some View {
        HStack {
            TextField(name, text: $pathString)
            Button {
                
            } label: {
                Image(systemName: "folder.badge.plus")
            }
        }
    }
}

struct DirectorySelectTextField_Previews: PreviewProvider {
    static var previews: some View {
        DirectorySelectTextField(name: "Storage Root Path")
    }
}
