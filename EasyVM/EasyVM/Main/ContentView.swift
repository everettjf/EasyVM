//
//  ContentView.swift
//  EasyVM
//
//  Created by everettjf on 2022/6/24.
//
import Foundation
import SwiftUI


struct ContentView: View {
    @State private var selectedMenuItem: SidebarMenu = .machines
    
    var body: some View {
        NavigationSplitView {
            List(SidebarMenu.allCases, selection: $selectedMenuItem) { menu in
                NavigationLink(value: menu) {
                    SidebarItemLabel(menu: menu)
                }
                .listItemTint(menu.color)
            }
        } detail: {
            switch selectedMenuItem {
            case .machines:
                MachinesDetailHomeView()
            case .documents:
                DocumentsDetailHomeView()
            case .community:
                CommunityDetailHomeView()
            case .issues:
                IssuesDetailHomeView()
            case .about:
                AboutDetailHomeView()
            }
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
