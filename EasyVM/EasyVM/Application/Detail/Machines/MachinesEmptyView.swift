//
//  MachinesEmptyView.swift
//  EasyVM
//
//  Created by everettjf on 2022/10/2.
//

import SwiftUI


struct MachinesEmptyButtonView: View {
    let image: String
    let title: String
    
    @State private var borderWidth: CGFloat = 0
    
    var body: some View {
        
        VStack {
            Image(systemName: image)
                .font(.system(size: 50))
                .frame(width: 50, height: 50)
            Text(title)
                .font(.caption)
        }
        .padding()
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .stroke(Color.gray, lineWidth: borderWidth)
        )
        .shadow(radius: 16)
        .onHover { hover in
            if hover {
                borderWidth = 1
            } else {
                borderWidth = 0
            }
        }
    }
}

struct MachinesEmptyView: View {
    @Environment(\.openWindow) var openWindow
    var body: some View {
        VStack {
            Text("No virtual machines found")
                .font(.title)
                .padding(.bottom, 2)
            Text("You could create a new virtual machine or drop an existing *.ezvm virtual machine here")
                .font(.caption)
                .padding(.bottom, 20)
            
            HStack {
                Spacer()
                
                MachinesEmptyButtonView(image: "plus.diamond", title: "Create new virtual machine")
                    .onTapGesture {
                        openWindow(id: "create-machine-guide")
                    }
                MachinesEmptyButtonView(image: "folder.badge.plus", title: "Add existing virtual machine")
                    .onTapGesture {
                        sharedAppConfigManager.addVMPathWithSelect()
                    }
                
                Spacer()
            }
        }
    }
}
struct MachinesEmptyView_Previews: PreviewProvider {
    static var previews: some View {
        MachinesEmptyView()
            .frame(width: 600, height: 400)
    }
}
