//
//  IssuesDetailView.swift
//  EasyVM
//
//  Created by everettjf on 2022/8/28.
//

import SwiftUI
import AppKit

#if arch(arm64)
struct IssuesDetailHomeView: View {

    @State private var copiedDiagnostics = false

    var body: some View {
        VStack(spacing: 12) {
            Spacer()

            Image(systemName: "ladybug")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)

            Text("Found a bug or have an idea?")
                .font(.title2)
                .fontWeight(.bold)

            Text("Issues are tracked on GitHub. Links open in your browser.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.bottom, 8)

            DetailLinkCardView(
                image: "plus.bubble",
                title: "Report a Bug / Request a Feature",
                subtitle: "Open a new GitHub issue",
                urlString: "https://github.com/everettjf/easyvm/issues/new"
            )
            DetailLinkCardView(
                image: "list.bullet.rectangle",
                title: "Browse Open Issues",
                subtitle: "See what is already reported",
                urlString: "https://github.com/everettjf/easyvm/issues"
            )

            // one click version info for pasting into bug reports
            HStack(spacing: 8) {
                Text(AppInfo.diagnosticText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Button {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(AppInfo.diagnosticText, forType: .string)
                    copiedDiagnostics = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        copiedDiagnostics = false
                    }
                } label: {
                    Image(systemName: copiedDiagnostics ? "checkmark" : "doc.on.doc")
                    Text(copiedDiagnostics ? "Copied" : "Copy")
                }
                .controlSize(.small)
            }
            .padding(.top, 8)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Issues - EasyVM")
    }
}

struct IssuesDetailHomeView_Previews: PreviewProvider {
    static var previews: some View {
        IssuesDetailHomeView()
    }
}

#endif
