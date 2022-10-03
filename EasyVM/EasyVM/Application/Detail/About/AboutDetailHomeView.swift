//
//  AboutDetailView.swift
//  EasyVM
//
//  Created by everettjf on 2022/8/28.
//

import SwiftUI

struct AboutDetailHomeView: View {
    var body: some View {
        VMWebView(url: URL(string:"https://easyvm.github.io")!)
            .navigationTitle("About - EasyVM")
    }
}

struct AboutDetailHomeView_Previews: PreviewProvider {
    static var previews: some View {
        AboutDetailHomeView()
    }
}
