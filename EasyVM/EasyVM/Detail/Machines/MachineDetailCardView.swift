//
//  MachineDetailCardView.swift
//  EasyVM
//
//  Created by everettjf on 2022/9/4.
//

import SwiftUI

struct MachineDetailCardView: View {
    
    let model: VMModel
    
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
                    Text("Memory: \(model.config.memory.description)")
                }
                .font(.caption2)
                
//                HStack(alignment: .top, spacing: 2) {
//                    Image(systemName: "circle.hexagonpath")
//                    Text("Attributes: \(vm.attributes)")
//                        .lineLimit(3)
//                }
//                .font(.caption2)
                
                HStack(alignment: .top, spacing: 2) {
                    Image(systemName: "captions.bubble")
                    Text("Description: \(model.config.remark)")
                        .lineLimit(3)
                }
                .font(.caption2)
            }
            
            HStack {
                Button {
                    
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
                    
                } label: {
                    Image(systemName: "slider.vertical.3")
                }
                .buttonStyle(.borderless)

            }
        }
        .padding(.all, 10)
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .stroke(.gray, lineWidth: 1)
        )
        .shadow(radius: 16)
        .frame(width: 230, height: 330)
    }
}
