//
//  AboutDetailView.swift
//  EasyVM
//
//  Created by everettjf on 2022/8/28.
//

import SwiftUI

#if arch(arm64)
struct AboutDetailHomeView: View {
    var body: some View {
        VMWebView(url: URL(string:"https://easyvm.app")!)
            .navigationTitle("About - EasyVM")
    }
}

struct AboutDetailHomeView_Previews: PreviewProvider {
    static var previews: some View {
        AboutDetailHomeView()
    }
}

#endif
