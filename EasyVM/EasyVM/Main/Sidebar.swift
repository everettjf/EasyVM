//
//  Sidebar.swift
//  EasyVM
//
//  Created by everettjf on 2022/8/28.
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
            return "All about the app"
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
    let menu: SidebarMenu

    var body: some View {
        Label {
            VStack(alignment: .leading) {
                Text(menu.name)
                    .padding(.bottom, 2)
                Text(menu.subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: menu.imageName)
                .symbolVariant(.circle.fill)
        }
        .padding(.top, 7)
        .padding(.bottom, 7)
    }
}
