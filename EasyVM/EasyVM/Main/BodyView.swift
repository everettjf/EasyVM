//
//  BodyView.swift
//  EasyVM
//
//  Created by gipyzarc on 2022/6/29.
//

import SwiftUI

struct BodyView: View {
    
    
    var body: some View {
        List(allVirtualMachines) { item in
            VStack {
                HStack {
                    Text(item.type.name)
                    Text(item.emoji)
                    Text(item.name)
                    Spacer()
                    Text(item.rootPath)
                }
            }
        }
    }
}

struct BodyView_Previews: PreviewProvider {
    static var previews: some View {
        BodyView()
            .frame(width: 630, height: 400)
    }
}
