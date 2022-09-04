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
    let remark: String
    let disk: String
    let cpu: Int
    let memory: String
    let attributes: String
}

class MyVMStore: ObservableObject {
    @Published var vms: [MyVM] = [
        MyVM(osType: .macOS, name: "My first macOS", remark: "This is my first macOS virutal machine created from EasyVM which is super easy", disk: "64GB", cpu: 1, memory: "4GB", attributes: "NAT Network, Input/Output Audio Stream, ..."),
        
        MyVM(osType: .linux, name: "My first linux", remark: "This is my first linux virutal machine created from EasyVM which is super easy", disk: "64GB", cpu: 2, memory: "4GB", attributes: "NAT Network, Input/Output Audio Stream, ..."),
        
        MyVM(osType: .macOS, name: "Her first macOS", remark: "This is her first macOS virutal machine created from EasyVM which is super easy", disk: "32GB", cpu: 2, memory: "4GB", attributes: "NAT Network, Input/Output Audio Stream, ..."),
        
        MyVM(osType: .macOS, name: "Her second macOS", remark: "This is her second macOS virutal machine created from EasyVM which is super easy", disk: "16GB", cpu: 1, memory: "4GB", attributes: "NAT Network, Input/Output Audio Stream, ..."),
        
        MyVM(osType: .linux, name: "Her first linux", remark: "This is her first linux virutal machine created from EasyVM which is super easy", disk: "32GB", cpu: 2, memory: "6GB", attributes: "NAT Network, Input/Output Audio Stream, ..."),
        
    ]
}


enum AttendanceScope {
    case inPerson
    case online
}

struct AttendeeToken: Identifiable, Equatable, Hashable {
    enum Guts {
        case name
        case location
        case status
    }
    
    let guts: Guts
    var query: String = .init()
    
    var id: String {
        self.systemImage
    }
    
    static let allCases: [AttendeeToken] = [.name, .location, .status]
    
    mutating func displayName(_ query: String) -> String {
        self.query = query
        switch guts {
        case .name: return "Name contains: \(query)"
        case .location: return "City contains: \(query)"
        case .status: return "Status contains: \(query)"
        }
    }
    
    var systemImage: String {
        switch guts {
        case .name: return "person"
        case .location: return "location.square"
        case .status: return "person.crop.circle.badge"
        }
    }
    
    static let name: AttendeeToken = .init(guts: .name)
    static let location: AttendeeToken = .init(guts: .location)
    static let status: AttendeeToken = .init(guts: .status)
}

struct MachinesDetailView: View {
    @StateObject private var vmStore = MyVMStore()
    @State private var selection = Set<MyVM.ID>()
    
    // searchable
    @State private var tokens: [AttendeeToken] = .init()
    @State private var query: String = .init()
    @State private var scope: AttendanceScope = .inPerson
    
    
    var table: some View {
        Table(vmStore.vms, selection: $selection) {
            TableColumn("OS") { vm in
                Text("\(vm.osType.rawValue)")
                    .frame(height: 60)
            }
            .width(50)
            
            TableColumn("Name") { vm in
                Text("\(vm.name)")
            }
            .width(min:150, ideal:150)
            
            TableColumn("Disk") { vm in
                Text("\(vm.disk)")
            }
            .width(50)
            
            TableColumn("CPU Count") { vm in
                Text("\(vm.cpu)")
            }
            .width(65)
            
            TableColumn("Memory") { vm in
                Text("\(vm.memory)")
            }
            .width(50)
            
            TableColumn("Attributes") { vm in
                Text("\(vm.attributes)")
                    .lineLimit(nil)
                    .multilineTextAlignment(.leading)
            }
            .width(min:100, ideal: 100)
            
            TableColumn("Description") { vm in
                Text("\(vm.remark)")
                    .lineLimit(nil)
                    .multilineTextAlignment(.leading)
            }
            .width(min:100, ideal: 200)
            
        }
    }
    
    var body: some View {
        NavigationStack {
            table
                .navigationTitle("Virtual Machines")
                .contextMenu(forSelectionType: MyVM.ID.self, menu: { selection in
                    if selection.isEmpty {
                        Button("No selection") {  }
                    } else if selection.count == 1 {
                        Button("select 1") {  }
                    } else {
                        Button("Select > 1") {  }
                    }
                })
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

struct MachinesDetailView_Previews: PreviewProvider {
    static var previews: some View {
        MachinesDetailView()
            .frame(width: 630, height: 400)
    }
}
