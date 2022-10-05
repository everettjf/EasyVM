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
    case community = "Community"
    case issues = "Issues"
    case about = "About"
    
    var name: String { rawValue }
    
    var color: Color {
        switch self {
        case .machines:
            return globalPalettes[0]
        case .community:
            return globalPalettes[1]
        case .issues:
            return globalPalettes[2]
        case .about:
            return globalPalettes[3]
        }
    }
    
    var imageName: String {
        switch self {
        case .machines:
            return "party.popper"
        case .community:
            return "envelope.open"
        case .issues:
            return "ladybug"
        case .about:
            return "face.smiling"
        }
    }
    
    var id: String { rawValue }
    
    var subtitle: String {
        switch self {
        case .machines:
            return "Created virtual machines"
        case .community:
            return "Let's talk anything"
        case .issues:
            return "Create an issue or new ideas"
        case .about:
            return "All about the app"
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
