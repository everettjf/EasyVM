//
//  StepperGuideView.swift
//  EasyVM
//
//  Created by everettjf on 2022/9/7.
//

import SwiftUI

struct StepperGuideStepItemView: View {
    let systemImage: String
    let name: String
    let subtitle: String
    let pointing: Bool
    
    var body: some View {
        Label {
            HStack {
                VStack(alignment: .leading) {
                    Text(name)
                        .padding(.bottom, 2)
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
                .fontWeight(pointing ? .bold : .light)
                Spacer()
                
                Image(systemName: "arrowshape.left")
                    .opacity(pointing ? 1 : 0)
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
    let subtitle: String
    let content: AnyView
}

class StepperGuideDataObject: ObservableObject {
    @Published var current: Int = 0
    @Published var stepCount: Int = 0
    
    func moveNextStep() {
        if current >= stepCount - 1 {
            return
        }
        current += 1
    }
    
    func isStepCompletion() -> Bool {
        return current == stepCount - 1
    }
    
    func getNextButtonText() -> String {
        if isStepCompletion() {
            return "Done"
        }
        return "Next"
    }
}

struct StepperGuideView: View {
    
    @ObservedObject var state = StepperGuideDataObject()
    let steps: [StepperGuideItem]
    
    init(steps: [StepperGuideItem]) {
        self.steps = steps
        self.state.stepCount = self.steps.count
    }
    
    init() {
        self.steps = [
            StepperGuideItem(systemImage: "1.circle", name: "System Type", subtitle: "Create macOS or Linux ?", content: AnyView(Text("choose system type"))),
            StepperGuideItem(systemImage: "2.circle", name: "System Image", subtitle: "Download or choose ipsw/iso file ?", content: AnyView(Text("choose system image"))),
            StepperGuideItem(systemImage: "3.circle", name: "Configuration", subtitle: "Config virtual devices such as size of disk, network type...", content: AnyView(Text("confir system type"))),
            StepperGuideItem(systemImage: "4.circle", name: "Creating", subtitle: "Start creating virtual machines...", content: AnyView(Text("completion"))),
            StepperGuideItem(systemImage: "5.circle", name: "Completion", subtitle: "Congratulations", content: AnyView(Text("completion"))),
        ]
        
        self.state.stepCount = self.steps.count
    }
    
    var body: some View {
        HStack(alignment:.top) {
            VStack(alignment: .leading) {
                ForEach(0..<steps.count, id: \.self) { index in
                    StepperGuideStepItemView(systemImage: steps[index].systemImage, name: steps[index].name, subtitle: steps[index].subtitle, pointing: index == state.current)
                }
                Spacer()
            }
            .frame(width: 160)
            .padding()
            
            StepperGuideSeparatorView()
            
            VStack {
                HStack {
                    ZStack {
                        ForEach(0..<steps.count, id: \.self) { index in
                            steps[index].content
                                .opacity(index == state.current ? 1 : 0)
                        }
                    }
                    Spacer()
                }
                Spacer()
                
                HStack {
                    Spacer()
                    Button {
                        state.moveNextStep()
                    } label: {
                        Text(state.getNextButtonText())
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
