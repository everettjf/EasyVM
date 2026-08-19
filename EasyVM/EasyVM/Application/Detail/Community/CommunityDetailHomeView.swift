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
        VStack(spacing: 12) {
            Spacer()

            Image(systemName: "person.2.wave.2")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)

            Text("Join the community")
                .font(.title2)
                .fontWeight(.bold)

            Text("Questions, ideas and showcases are all welcome. Links open in your browser.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.bottom, 8)

            DetailLinkCardView(
                image: "bubble.left.and.bubble.right",
                title: "GitHub Discussions",
                subtitle: "Ask questions and share ideas",
                urlString: "https://github.com/everettjf/easyvm/discussions"
            )
            DetailLinkCardView(
                image: "message",
                title: "Discord",
                subtitle: "Chat with other users",
                urlString: "https://discord.gg/uxuy3vVtWs"
            )
            DetailLinkCardView(
                image: "star",
                title: "Star the project",
                subtitle: "github.com/everettjf/easyvm",
                urlString: "https://github.com/everettjf/easyvm"
            )

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Community - EasyVM")
    }
}

struct CommunityDetailHomeView_Previews: PreviewProvider {
    static var previews: some View {
        CommunityDetailHomeView()
    }
}

#endif
