//
//  CommunityDetailView.swift
//  EZVM
//
//  Created by everettjf on 2022/8/28.
//

import SwiftUI
import AppKit

#if arch(arm64)
struct CommunityDetailHomeView: View {
    @State private var copiedDiagnostics = false
    @State private var diagnosticError: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                Image(systemName: "person.2.wave.2")
                    .font(.system(size: 44))
                    .foregroundStyle(.secondary)
                    .padding(.top, 24)

                Text("Community & Feedback")
                    .font(.title2)
                    .fontWeight(.bold)

                Text("Chat with other users, report problems, or suggest improvements. Links open in your browser.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 8)

                DetailLinkCardView(
                    image: "message",
                    title: "Discord",
                    subtitle: "Chat with other users",
                    urlString: "https://discord.gg/eGzEaP6TzR"
                )
                DetailLinkCardView(
                    image: "plus.bubble",
                    title: "Report a Bug / Request a Feature",
                    subtitle: "Open a new GitHub issue",
                    urlString: "https://github.com/everettjf/ezvm/issues/new"
                )
                DetailLinkCardView(
                    image: "list.bullet.rectangle",
                    title: "Browse Open Issues",
                    subtitle: "See what is already reported",
                    urlString: "https://github.com/everettjf/ezvm/issues"
                )
                DetailLinkCardView(
                    image: "star",
                    title: "Star the project",
                    subtitle: "github.com/everettjf/ezvm",
                    urlString: "https://github.com/everettjf/ezvm"
                )

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
                Button("Export Diagnostic Report", systemImage: "square.and.arrow.up") {
                    do {
                        let url = try EZVMDiagnostics.export()
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    } catch let error as CocoaError where error.code == .userCancelled {
                        // The user intentionally dismissed the save panel.
                    } catch {
                        diagnosticError = error.localizedDescription
                    }
                }
                .accessibilityHint("Creates a report containing system information and virtual machine configuration")
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .frame(maxWidth: .infinity)

        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Community & Feedback - EZVM")
        .alert("Couldn’t export diagnostics", isPresented: Binding(
            get: { diagnosticError != nil },
            set: { if !$0 { diagnosticError = nil } }
        )) {
            Button("OK", role: .cancel) { diagnosticError = nil }
        } message: {
            Text(diagnosticError ?? "Unknown error")
        }
    }
}

struct CommunityDetailHomeView_Previews: PreviewProvider {
    static var previews: some View {
        CommunityDetailHomeView()
    }
}

#endif
