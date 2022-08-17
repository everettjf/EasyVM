//
//  DownloadImageView.swift
//  EasyVM
//
//  Created by everettjf on 2022/8/17.
//

import SwiftUI

struct DownloadImageView: View {
    
    var body: some View {
        VStack {
            
            VStack(alignment: .leading) {
                Text("Total Progress").font(.title2)
                
                ProgressView(value: 250, total: 1000)
                
                Text("25% - 250MB / 1000GB").font(.caption)
            }
            
            
            Button {
                
            } label: {
                Text("Start Download Latest macOS System Image")
            }

        }
        .padding()
    }
}

struct DownloadImageView_Previews: PreviewProvider {
    static var previews: some View {
        DownloadImageView()
    }
}
