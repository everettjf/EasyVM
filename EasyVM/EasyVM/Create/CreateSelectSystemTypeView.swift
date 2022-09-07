//
//  CreateSelectSystemTypeView.swift
//  EasyVM
//
//  Created by everettjf on 2022/9/7.
//

import SwiftUI

struct SystemCardView: View {
    let image: String
    let name: String
    
    @State private var borderColor: Color = .gray
    
    var body: some View {
        VStack {
            Image(systemName: image)
                .font(.system(size: 70))
                .frame(width:100,height: 120)
            
            Button {
                
            } label: {
                Text(name)
            }
            .buttonStyle(.borderless)
        }
        .padding()
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .stroke(borderColor, lineWidth: 1)
        )
        .shadow(radius: 16)
        .onHover { hover in
            if hover {
                borderColor = .blue
            } else {
                borderColor = .gray
            }
        }
    }
}



struct CreateSelectSystemTypeView: View {
    var body: some View {
        HStack(spacing: 30) {
            SystemCardView(image: "macpro.gen3", name: "macOS")
            SystemCardView(image: "pc", name: "Linux")
        }
    }
}

struct CreateSelectSystemTypeView_Previews: PreviewProvider {
    static var previews: some View {
        CreateSelectSystemTypeView()
            .frame(width:500, height: 500)
    }
}
