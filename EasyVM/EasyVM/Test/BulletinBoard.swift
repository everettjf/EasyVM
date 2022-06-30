//
//  BulletinBoard.swift
//  EasyVM
//
//  Created by gipyzarc on 2022/6/26.
//

import Foundation
import SwiftUI

private let allPosts: [String] = [
    "Did you know: On your third birthday, you are celebrating your 4.0 release.",
]

struct BulletinBoard: View {

    @State var currentPostIndex: Int = 0

    var currentPost: String {
        allPosts[currentPostIndex]
    }

    var body: some View {
        VStack(spacing: 16) {

            VStack(spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text("“")
                        .font(.custom("Helvetica", size: 50).bold())
                        .baselineOffset(-23)
                        .foregroundStyle(.tertiary)

                    Text("Party Bulletin Board")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.secondary)

                    Spacer()

                    Text("June 6, 2022")
                        .font(.headline.weight(.regular))
                        .foregroundStyle(.secondary)
                }
                .frame(height: 20)


                Text(currentPost)
                    .font(.system(size: 18))
                    .multilineTextAlignment(.center)
            }
            .padding(.bottom, 4)

            Divider()

            HStack {
                Button {

                } label: {
                    Label("Calendar", systemImage: "calendar")
                }
                Button {
                    currentPostIndex = (currentPostIndex + 1) % allPosts.count
                } label: {
                    Text("Previous")
                        .frame(maxWidth: .infinity)
                }

                ShareLink(items: [currentPost])
            }
            .labelStyle(.iconOnly)
            .controlSize(.large)
        }
        .padding(16)
    }
}
