//
//  CommunityDetailView.swift
//  EasyVM
//
//  Created by everettjf on 2022/8/28.
//

import SwiftUI

#if arch(arm64)
struct CommunityDetailHomeView: View {
    var body: some View {
        VMWebView(url: URL(string:"https://discord.gg/uxuy3vVtWs")!)
            .navigationTitle("Community - EasyVM")
    }
}

struct CommunityDetailHomeView_Previews: PreviewProvider {
    static var previews: some View {
        CommunityDetailHomeView()
    }
}

#endif
