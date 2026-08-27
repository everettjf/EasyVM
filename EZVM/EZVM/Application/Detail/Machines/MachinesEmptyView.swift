//
//  MachinesEmptyView.swift
//  EZVM
//
//  Created by everettjf on 2022/10/2.
//

import SwiftUI


#if arch(arm64)
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
        VStack(spacing: 12) {
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("No virtual machines found")
                .font(.title2.weight(.semibold))
            Text("Create your first machine, or add an existing .ezvm bundle.")
                .foregroundStyle(.secondary)
                .padding(.bottom, 20)
            
            HStack {
                Spacer()
                
                Button {
                        openWindow(id: "create-machine-guide")
                    } label: {
                        Label("Create Virtual Machine", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                Button {
                        sharedAppConfigManager.addVMPathWithSelect()
                    } label: {
                        Label("Add Existing", systemImage: "folder.badge.plus")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                
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

#endif
