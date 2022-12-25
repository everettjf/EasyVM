//
//  IssuesDetailView.swift
//  EasyVM
//
//  Created by everettjf on 2022/8/28.
//

import SwiftUI

#if arch(arm64)
struct IssuesDetailHomeView: View {
    var body: some View {
        VMWebView(url: URL(string:"https://github.com/everettjf/EasyVM/issues")!)
            .navigationTitle("Issues - EasyVM")
    }
}

struct IssuesDetailHomeView_Previews: PreviewProvider {
    static var previews: some View {
        IssuesDetailHomeView()
    }
}

#endif
