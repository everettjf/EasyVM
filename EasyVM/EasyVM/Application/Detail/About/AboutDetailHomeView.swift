//
//  AboutDetailView.swift
//  EasyVM
//
//  Created by everettjf on 2022/8/28.
//

import SwiftUI
import AppKit

#if arch(arm64)

struct AppInfo {
    static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "-"
    }

    static var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "-"
    }

    static var diagnosticText: String {
        "EasyVM \(version) (\(build)) on macOS \(ProcessInfo.processInfo.operatingSystemVersionString)"
    }
}


// a clickable row that opens a link in the default browser
struct DetailLinkCardView: View {
    let image: String
    let title: String
    let subtitle: String
    let urlString: String

    @State private var borderColor: Color = .gray

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: image)
                .font(.system(size: 26))
                .frame(width: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Image(systemName: "arrow.up.forward.square")
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: 480)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(borderColor, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onHover { hover in
            borderColor = hover ? .blue : .gray
        }
        .onTapGesture {
            MacKitUtil.openUrl(urlString)
        }
    }
}


struct AboutDetailHomeView: View {
    var body: some View {
        VStack(spacing: 12) {
            Spacer()

            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)

            Text("EasyVM")
                .font(.largeTitle)
                .fontWeight(.bold)

            Text("Version \(AppInfo.version) (\(AppInfo.build))")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("A simple, native virtual machine app for Apple silicon Macs, built on Apple's Virtualization framework.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 420)
                .padding(.bottom, 8)

            DetailLinkCardView(
                image: "globe",
                title: "Website",
                subtitle: "xnu.app/easyvm",
                urlString: "https://xnu.app/easyvm"
            )
            DetailLinkCardView(
                image: "chevron.left.forwardslash.chevron.right",
                title: "Source Code",
                subtitle: "github.com/everettjf/easyvm",
                urlString: "https://github.com/everettjf/easyvm"
            )
            DetailLinkCardView(
                image: "shippingbox",
                title: "Releases",
                subtitle: "Download the latest version",
                urlString: "https://github.com/everettjf/easyvm/releases"
            )

            Spacer()

            Text("Open source under the MIT license")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.bottom, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("About - EasyVM")
    }
}

struct AboutDetailHomeView_Previews: PreviewProvider {
    static var previews: some View {
        AboutDetailHomeView()
    }
}

#endif
