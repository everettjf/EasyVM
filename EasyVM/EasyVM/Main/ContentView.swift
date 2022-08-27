//
//  ContentView.swift
//  EasyVM
//
//  Created by gipyzarc on 2022/6/24.
//
import Foundation
import SwiftUI

enum PartyTask: String, Identifiable, CaseIterable, Hashable {
    case food = "Food"
    case music = "Music"
    case supplies = "Supplies"
    case invitations = "Invitations"
    case eventDetails = "Event Details"
    case activities = "Activities"
    case funProjection = "Fun Projection"
    case vips = "VIPs"
    case photosFilter = "Photos Filter"
    
    var name: String { rawValue }
    
    var color: Color {
        switch self {
        case .food:
            return globalPalettes[0]
        case .supplies:
            return globalPalettes[1]
        case .invitations:
            return globalPalettes[2]
        case .eventDetails:
            return globalPalettes[3]
        case .funProjection:
            return globalPalettes[4]
        case .activities:
            return globalPalettes[5]
        case .vips:
            return globalPalettes[6]
        case .music:
            return globalPalettes[7]
        case .photosFilter:
            return globalPalettes[8]
        }
    }
    
    var imageName: String {
        switch self {
        case .food:
            return "birthday.cake"
        case .supplies:
            return  "party.popper"
        case .invitations:
            return "envelope.open"
        case .eventDetails:
            return "calendar.badge.clock"
        case .funProjection:
            return "gauge.medium"
        case .activities:
            return "bubbles.and.sparkles"
        case .vips:
            return "person.2"
        case .music:
            return  "music.mic"
        case .photosFilter:
            return "camera.filters"
        }
    }
    
    var id: String { rawValue }
    
    var subtitle: String {
        switch self {
        case .food:
            return "Apps, 'Zerts and Cakes"
        case .supplies:
            return "Streamers, Plates, Cups"
        case .invitations:
            return "Sendable, Non-Transferable"
        case .eventDetails:
            return "Date, Duration, And Placement"
        case .funProjection:
            return "Beta — How Fun Will Your Party Be?"
        case .activities:
            return "Dancing, Paired Programing"
        case .vips:
            return "User Interactive Guests"
        case .music:
            return "Song Requests & Karaoke"
        case .photosFilter:
            return "Filtering and Mapping"
        }
    }
    
    var emoji: String {
        switch self {
        case .food:
            return "🎂"
        case .music:
            return "🎤"
        case .supplies:
            return "🎉"
        case .invitations:
            return "📨"
        case .eventDetails:
            return "🗓"
        case .funProjection:
            return "🧭"
        case .activities:
            return "💃"
        case .vips:
            return "⭐️"
        case .photosFilter:
            return "📸"
        }
    }
}



struct TaskLabel: View {
    let task: PartyTask

    var body: some View {
        Label {
            VStack(alignment: .leading) {
                Text(task.name)
                Text(task.subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: task.imageName)
                .symbolVariant(.circle.fill)
        }
    }
}

struct ContentView: View {
    @State private var selectedTask: PartyTask = .food
    
    var body: some View {
        NavigationSplitView {
            List(PartyTask.allCases, selection: $selectedTask) { task in
                NavigationLink(value: task) {
                    TaskLabel(task: task)
                }
                .listItemTint(task.color)
            }
        } detail: {
            if case .food = selectedTask {
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
