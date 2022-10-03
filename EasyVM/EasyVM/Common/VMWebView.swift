//
//  VMWebView.swift
//  EasyVM
//
//  Created by everettjf on 2022/10/3.
//

import SwiftUI
import WebKit


class VMInternalWebView: WKWebView {
    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }
    
    init() {
        super.init(frame: .zero, configuration: WKWebViewConfiguration())
        
        self.setValue(false, forKey: "drawsBackground")
    }
}

struct VMInternalWebWrapView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> VMInternalWebView {
        let webView = VMInternalWebView()
        return webView
    }

    func updateNSView(_ view: VMInternalWebView, context: Context) {
        let request = URLRequest(url: url)
        view.load(request)
    }
}

struct VMWebView: View {
    let url: URL
    
    var body: some View {
        VMInternalWebWrapView(url: url)
    }
}

struct VMWebView_Previews: PreviewProvider {
    static var previews: some View {
        VMWebView(url: URL(string: "https://easyvm.github.io")!)
    }
}
