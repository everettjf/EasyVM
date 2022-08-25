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
            return palette[0]
        case .supplies:
            return palette[1]
        case .invitations:
            return palette[2]
        case .eventDetails:
            return palette[3]
        case .funProjection:
            return palette[4]
        case .activities:
            return palette[5]
        case .vips:
            return palette[6]
        case .music:
            return palette[7]
        case .photosFilter:
            return palette[8]
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

private let palette: [Color] = [
    Color(red: 0.73, green: 0.20, blue: 0.20),
    Color(red: 0.95, green: 0.66, blue: 0.24),
    Color(red: 0.14, green: 0.29, blue: 0.49),
    Color(red: 0.46, green: 0.76, blue: 0.67),
    Color(red: 0.30, green: 0.33, blue: 0.22),
    Color(red: 0.49, green: 0.55, blue: 0.64),
    Color(red: 0.92, green: 0.53, blue: 0.30),
    Color(red: 0.20, green: 0.45, blue: 0.55),
    Color(red: 0.41, green: 0.45, blue: 0.45),
    Color(red: 0.87, green: 0.67, blue: 0.61)
]


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
