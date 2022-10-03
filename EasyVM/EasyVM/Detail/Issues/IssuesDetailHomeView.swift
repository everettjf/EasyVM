//
//  IssuesDetailView.swift
//  EasyVM
//
//  Created by everettjf on 2022/8/28.
//

import SwiftUI

struct IssuesDetailHomeView: View {
    var body: some View {
        VMWebView(url: URL(string:"https://github.com/easyvm/main")!)
            .navigationTitle("Issues - EasyVM")
    }
}

struct IssuesDetailHomeView_Previews: PreviewProvider {
    static var previews: some View {
        IssuesDetailHomeView()
    }
}
