//
//  ContentView.swift
//  EasyVM
//
//  Created by gipyzarc on 2022/6/24.
//
import Foundation
import SwiftUI

enum SidebarMenu: String, Identifiable, CaseIterable, Hashable {
    case machines = "Machines"
    case documents = "Documents"
    case community = "Community"
    case issues = "Issues"
    case about = "About"
    
    var name: String { rawValue }
    
    var color: Color {
        switch self {
        case .machines:
            return globalPalettes[0]
        case .documents:
            return globalPalettes[1]
        case .community:
            return globalPalettes[2]
        case .issues:
            return globalPalettes[3]
        case .about:
            return globalPalettes[4]
        }
    }
    
    var imageName: String {
        switch self {
        case .machines:
            return "birthday.cake"
        case .documents:
            return  "party.popper"
        case .community:
            return "envelope.open"
        case .issues:
            return "calendar.badge.clock"
        case .about:
            return "gauge.medium"
        }
    }
    
    var id: String { rawValue }
    
    var subtitle: String {
        switch self {
        case .machines:
            return "Created virtual machines"
        case .documents:
            return "How to create, use"
        case .community:
            return "Let's talk anything"
        case .issues:
            return "Create an issue or new ideas"
        case .about:
            return "All about current app"
        }
    }
    
    var emoji: String {
        switch self {
        case .machines:
            return "🎂"
        case .documents:
            return "🎤"
        case .community:
            return "🎉"
        case .issues:
            return "📨"
        case .about:
            return "🗓"
        }
    }
}



struct SidebarItemLabel: View {
    let task: SidebarMenu

    var body: some View {
        Label {
            VStack(alignment: .leading) {
                Text(task.name)
                    .padding(.bottom, 2)
                Text(task.subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: task.imageName)
                .symbolVariant(.circle.fill)
        }
        .padding(.top, 7)
        .padding(.bottom, 7)
    }
}

struct ContentView: View {
    @State private var selectedTask: SidebarMenu = .machines
    
    var body: some View {
        NavigationSplitView {
            List(SidebarMenu.allCases, selection: $selectedTask) { task in
                NavigationLink(value: task) {
                    SidebarItemLabel(task: task)
                }
                .listItemTint(task.color)
            }
        } detail: {
            if case .machines = selectedTask {
                BodyView()
            } else {
                selectedTask.color
            }
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
