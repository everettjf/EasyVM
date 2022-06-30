//
//  VMStartItemView.swift
//  EasyVM
//
//  Created by gipyzarc on 2022/6/29.
//

import SwiftUI

struct VMStartItemView: View {
    let name: String
    
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(name)
                    .font(.title3)
                Spacer()
            }
            .padding(.all)
            
            Rectangle()
                .foregroundColor(Color.gray)
        }
        .frame(width: 200, height: 200)
        .padding(.all)
    }
}

struct VMStartItemView_swift_Previews: PreviewProvider {
    static var previews: some View {
        VMStartItemView(name: "macOS")
    }
}
