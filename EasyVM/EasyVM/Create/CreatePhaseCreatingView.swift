//
//  CreatePhaseCreatingView.swift
//  EasyVM
//
//  Created by everettjf on 2022/9/12.
//

import SwiftUI

struct CreatePhaseCreatingView: View {
    var body: some View {
        
        VStack {
            Text("Creating")
            ProgressView(value: 250, total: 1000)
            
            List{
                Text("Creating...").font(.caption)
                Text("Creating...").font(.caption)
                Text("Creating...").font(.caption)
                Text("Creating...").font(.caption)
                Text("Creating...").font(.caption)
                Text("Creating...").font(.caption)
                Text("Creating...").font(.caption)
            }
        }
    }
}

struct CreatePhaseCreatingView_Previews: PreviewProvider {
    static var previews: some View {
        CreatePhaseCreatingView()
    }
}