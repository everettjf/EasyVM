//
//  MachineDetailInvalidCardView.swift
//  EasyVM
//
//  Created by everettjf on 2022/10/3.
//

import SwiftUI

#if arch(arm64)
struct MachineDetailInvalidCardView: View {
    let item: HomeItemVMModel
    
    var body: some View {
        VStack {
            Text("Invalid")
                .font(.title)
                .padding(.all)
            Text(item.rootPath.path(percentEncoded: false))
                .font(.caption)
                .lineLimit(5)
                .multilineTextAlignment(.leading)
        }
        .padding(.all, 10)
        .frame(width: 230, height: 330)
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .stroke(.gray, lineWidth: 1)
        )
        .padding(.all, 5)
    }
}

//struct MachineDetailInvalidCardView_Previews: PreviewProvider {
//    static var previews: some View {
//        MachineDetailInvalidCardView()
//    }
//}

#endif
