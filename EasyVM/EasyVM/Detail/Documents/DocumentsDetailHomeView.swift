//
//  DocumentsDetailView.swift
//  EasyVM
//
//  Created by everettjf on 2022/8/28.
//

import SwiftUI

struct DocumentsDetailHomeView: View {
    var body: some View {
        VMWebView(url: URL(string:"https://easyvm.github.io/documents")!)
            .navigationTitle("Documents - EasyVM")
    }
}

struct DocumentsDetailHomeView_Previews: PreviewProvider {
    static var previews: some View {
        DocumentsDetailHomeView()
    }
}
