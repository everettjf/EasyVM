//
//  StepperGuideView.swift
//  EasyVM
//
//  Created by everettjf on 2022/9/7.
//

import SwiftUI

struct StepperGuideStepItemView: View {
    let name: String
    let systemImage: String
    
    var body: some View {
        Label {
            HStack {
                Text(name)
                    .font(.body)
                    .padding(.bottom, 2)
                Spacer()
            }
        } icon: {
            Image(systemName: systemImage)
                .symbolVariant(.circle.fill)
        }
        .padding([.top, .bottom], 7)
    }
}

struct StepperGuideSeparatorView: View {
    var body: some View {
        Color.gray
            .frame(width: 1)
    }
}

struct StepperGuideItem : Identifiable {
    let id = UUID()
    let systemImage: String
    let name: String
    let content: AnyView
}

class StepperGuideDataObject: ObservableObject {
    @Published var current: Int = 0
    
    func moveNext() {
        current += 1
    }
}

struct StepperGuideView: View {
    
    @ObservedObject var state = StepperGuideDataObject()
    let steps: [StepperGuideItem]
    
    init(steps: [StepperGuideItem]) {
        self.steps = steps
    }
    
    init() {
        self.steps = [
            StepperGuideItem(systemImage: "1.circle", name: "Choose System Type", content: AnyView(Text("choose system type"))),
            StepperGuideItem(systemImage: "2.circle", name: "Choose System Type", content: AnyView(Text("choose system type"))),
            StepperGuideItem(systemImage: "3.circle", name: "Choose System Type", content: AnyView(Text("choose system type"))),
            StepperGuideItem(systemImage: "4.circle", name: "Choose System Type", content: AnyView(Text("choose system type"))),
            StepperGuideItem(systemImage: "5.circle", name: "Choose System Type", content: AnyView(Text("choose system type"))),
        ]
    }
    
    var body: some View {
        HStack(alignment:.top) {
            VStack(alignment: .leading) {
                ForEach(steps) { step in
                    StepperGuideStepItemView(name: step.name, systemImage: step.systemImage)
                }
                Spacer()
            }
            .frame(width: 140)
            .padding()
            
            StepperGuideSeparatorView()
            
            VStack {
                HStack {
                    Text("content")
                    Spacer()
                }
                Spacer()
                
                HStack {
                    Spacer()
                    Button {
                        state.moveNext()
                    } label: {
                        Text("Next")
                    }

                }
            }
            .padding()
        }
    }
}

struct StepperGuideView_Previews: PreviewProvider {
    static var previews: some View {
        StepperGuideView()
            .frame(width: 600, height: 300)
    }
}
