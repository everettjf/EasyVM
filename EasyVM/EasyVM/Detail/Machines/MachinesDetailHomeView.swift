//
//  BodyView.swift
//  EasyVM
//
//  Created by everettjf on 2022/6/29.
//

import SwiftUI

struct MyVM : Identifiable, Hashable {
    let id = UUID()
    let osType: VMModelOSType
    let name: String
    let color: Color
    let remark: String
    let disk: String
    let cpu: Int
    let memory: String
    let attributes: String
}

class MyVMStore: ObservableObject {
    @Published var vms: [MyVM] = [
        MyVM(osType: .macOS, name: "My first macOS", color: .pink, remark: "This is my first macOS virutal machine created from EasyVM which is super easy", disk: "64GB", cpu: 1, memory: "4GB", attributes: "NAT Network, Input/Output Audio Stream, ..."),
        
        MyVM(osType: .linux, name: "My first linux", color: .blue, remark: "This is my first linux virutal machine created from EasyVM which is super easy", disk: "64GB", cpu: 2, memory: "4GB", attributes: "NAT Network, Input/Output Audio Stream, ..."),
        
        MyVM(osType: .macOS, name: "Her first macOS", color: .indigo, remark: "This is her first macOS virutal machine created from EasyVM which is super easy", disk: "32GB", cpu: 2, memory: "4GB", attributes: "NAT Network, Input/Output Audio Stream, ..."),
        
        MyVM(osType: .macOS, name: "Her second macOS", color: .yellow, remark: "This is her second macOS virutal machine created from EasyVM which is super easy", disk: "16GB", cpu: 1, memory: "4GB", attributes: "NAT Network, Input/Output Audio Stream, ..."),
        
        MyVM(osType: .linux, name: "Her first linux", color: .green, remark: "This is her first linux virutal machine created from EasyVM which is super easy", disk: "32GB", cpu: 2, memory: "6GB", attributes: "NAT Network, Input/Output Audio Stream, ..."),
        
    ]
}



struct MachinesDetailHomeView: View {
    @StateObject private var vmStore = MyVMStore()
    
    let columns = [GridItem(.adaptive(minimum: 230, maximum: 230))]
    
    var grid: some View {
        LazyVGrid(columns: columns, alignment: .listRowSeparatorLeading) {
            ForEach(vmStore.vms) { item in
                MachineDetailCardView(vm: item)
            }
        }
    }
    
    var body: some View {
        NavigationStack {
            VStack {
                ScrollView {
                    grid
                }
            }
            .padding(.leading, 5)
            .padding(.trailing, 5)
            .navigationTitle("Virtual Machines - EasyVM")
            .toolbar(id: "toolbar") {
                ToolbarItem(id: "new", placement: .primaryAction) {
                    Button(action: {}) {
                        Label("New Virutal Machine", systemImage: "plus.diamond")
                    }
                }
                ToolbarItem(id: "share", placement: .automatic) {
                    Button(action: {}) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                }
            }
        }
        
    }
}

struct MachinesDetailHomeView_Previews: PreviewProvider {
    static var previews: some View {
        MachinesDetailHomeView()
            .frame(width: 500, height: 400)
    }
}
