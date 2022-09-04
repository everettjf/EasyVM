//
//  MachineDetailCardView.swift
//  EasyVM
//
//  Created by everettjf on 2022/9/4.
//

import SwiftUI


struct MachineDetailCardView: View {
    
    let vm: MyVM
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(vm.name)
                    .font(.headline)
                Spacer()
                Text(vm.osType == .linux ? "Linux" : "macOS")
                    .font(.footnote)
                    .fontWeight(.bold)
            }
            
            Rectangle()
                .foregroundColor(vm.color)
                .frame(height:120)
                .cornerRadius(5)
            

            Group {
                HStack(spacing: 2) {
                    Image(systemName: "doc.viewfinder.fill")
                    Text("Disk: \(vm.disk)")
                }
                .font(.caption2)
                HStack(spacing: 2) {
                    Image(systemName: "cpu")
                    Text("CPU: \(vm.cpu)")
                }
                .font(.caption2)
                HStack(spacing: 2) {
                    Image(systemName: "memorychip")
                    Text("Memory: \(vm.memory)")
                }
                .font(.caption2)
                
                HStack(alignment: .top, spacing: 2) {
                    Image(systemName: "circle.hexagonpath")
                    Text("Attributes: \(vm.attributes)")
                        .lineLimit(3)
                }
                .font(.caption2)
                
                HStack(alignment: .top, spacing: 2) {
                    Image(systemName: "captions.bubble")
                    Text("Description: \(vm.remark)")
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
            RoundedRectangle(cornerRadius: 16)
                .stroke(.blue, lineWidth: 1)
        )
        .shadow(radius: 16)
        .frame(width: 230, height: 330)
    }
    
}

struct MachineDetailCardView_Previews: PreviewProvider {
    static let width: CGFloat = 500
    
    static var previews: some View {
        MachineDetailCardView(vm: MyVM(osType: .macOS, name: "My first macOS", color: .indigo, remark: "This is my first macOS virutal machine created from EasyVM from EasyVM which is super easy", disk: "64GB", cpu: 1, memory: "4GB", attributes: "NAT Network, from EasyVM from EasyVM Input/Output Audio Stream, ..."))
            .preferredColorScheme(.dark)
            .frame(width: width, height: width)
        
        MachineDetailCardView(vm: MyVM(osType: .macOS, name: "My first macOS", color: .pink, remark: "This is my first macOS virutal", disk: "64GB", cpu: 1, memory: "4GB", attributes: "NAT Network, Input/Output Audio Stream, ..."))
            .preferredColorScheme(.light)
            .frame(width: width, height: width)
    }
}
