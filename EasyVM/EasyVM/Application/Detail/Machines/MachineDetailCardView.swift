//
//  MachineDetailCardView.swift
//  EasyVM
//
//  Created by everettjf on 2022/9/4.
//

import SwiftUI


#if arch(arm64)
struct MachineDetailCardAction {
    let onPlay: () -> Void
    let onEdit: () -> Void
}

struct MachineDetailCardView: View {
    
    let item: HomeItemVMModel
    let model: VMModel
    let action: MachineDetailCardAction
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(model.config.name)
                    .font(.headline)
                Spacer()
                Text(model.config.type == .linux ? "Linux" : "macOS")
                    .font(.footnote)
                    .fontWeight(.bold)
                    .padding(3)
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .stroke(.gray, lineWidth: 1)
                    )
            }
            
            Rectangle()
                .foregroundColor(Color.blue)
                .frame(height:120)
                .cornerRadius(5)
            

            Group {
                HStack(spacing: 2) {
                    Image(systemName: "doc.viewfinder.fill")
                    Text("Disk: \(model.displayDiskInfo)")
                }
                .font(.caption2)
                HStack(spacing: 2) {
                    Image(systemName: "cpu")
                    Text("CPU: \(model.config.cpu.count)")
                }
                .font(.caption2)
                HStack(spacing: 2) {
                    Image(systemName: "memorychip")
                    Text("Memory: \(model.displayMemoryInfo)")
                }
                .font(.caption2)
                
                HStack(alignment: .top, spacing: 2) {
                    Image(systemName: "circle.hexagonpath")
                    Text("Attributes: \(model.displayAttributeInfo)")
                        .lineLimit(3)
                }
                .font(.caption2)
                
                HStack(alignment: .top, spacing: 2) {
                    Image(systemName: "captions.bubble")
                    Text("Description: \(model.config.remark)")
                        .lineLimit(3)
                }
                .font(.caption2)
            }
            
            HStack {
                Button {
                    action.onPlay()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "play")
                        Text("Run")
                    }
                    .fontWeight(.bold)
                }
                .buttonStyle(.borderless)

                
                Spacer()
                Button {
                    action.onEdit()
                } label: {
                    Image(systemName: "slider.vertical.3")
                }
                .buttonStyle(.borderless)

            }
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

#endif
