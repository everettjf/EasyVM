//
//  BodyView.swift
//  EasyVM
//
//  Created by gipyzarc on 2022/6/29.
//

import SwiftUI

struct BodyView: View {
    
    private var gridItemLayout = [GridItem(.adaptive(minimum: 200))]
    
    var body: some View {
        
        ScrollView {
            LazyVGrid(columns: gridItemLayout) {
                ForEach(partyFoods) { item in
                    VMStartItemView(name: "\(item.emoji) \(item.name)")
                }
            }
        }
    }
}

struct BodyView_Previews: PreviewProvider {
    static var previews: some View {
        BodyView()
            .frame(width: 600, height: 500)
    }
}
