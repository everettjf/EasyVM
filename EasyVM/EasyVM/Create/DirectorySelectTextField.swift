//
//  DirectorySelectTextField.swift
//  EasyVM
//
//  Created by everettjf on 2022/8/6.
//

import SwiftUI

struct DirectorySelectTextField: View {
    
    @State private var pathString: String = ""
    
    var body: some View {
        HStack {
            TextField("", text: $pathString)
            Button {
                
            } label: {
                Image(systemName: "folder.badge.plus")
            }
        }
        .padding(.leading,0)
    }
}

struct DirectorySelectTextField_Previews: PreviewProvider {
    static var previews: some View {
        DirectorySelectTextField()
    }
}
