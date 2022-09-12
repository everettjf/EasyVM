//
//  StepperGuideView.swift
//  EasyVM
//
//  Created by everettjf on 2022/9/7.
//

import SwiftUI

struct CreateStepperGuideStepItemView: View {
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

struct CreateStepperGuideSeparatorView: View {
    var body: some View {
        Color.gray
            .frame(width: 1)
    }
}

struct CreateStepperGuideItem : Identifiable {
    let id = UUID()
    let systemImage: String
    let name: String
    let subtitle: String
    let content: AnyView
}

class CreateStepperGuideDataObject: ObservableObject {
    @Published var current: Int = 0
    @Published var stepCount: Int = 0
    
    func moveNextStep() {
        if current >= stepCount - 1 {
            return
        }
        current += 1
    }
    func movePreviousStep() {
        if current <= 0 {
            return
        }
        current -= 1
    }
    
    func isStepCompletion() -> Bool {
        return current == stepCount - 1
    }
    
    func isPreviousAvaliable() -> Bool {
        return current != 0
    }
    func getPreviousButtonText() -> String {
        return "Previous"
    }
    func getNextButtonText() -> String {
        if isStepCompletion() {
            return "Done"
        }
        return "Next"
    }
}

struct CreateStepperGuideView: View {
    
    @ObservedObject var state = CreateStepperGuideDataObject()
    let steps: [CreateStepperGuideItem]
    
    init(steps: [CreateStepperGuideItem]) {
        self.steps = steps
        self.state.stepCount = self.steps.count
    }
    
    init() {
        self.steps = [
            CreateStepperGuideItem(systemImage: "1.circle", name: "OS Type", subtitle: "Create macOS or Linux ?", content: AnyView(CreatePhaseChooseSystemTypeView())),
            CreateStepperGuideItem(systemImage: "2.circle", name: "Name", subtitle: "Name the machine", content: AnyView(CreatePhaseNameConfigView())),
            CreateStepperGuideItem(systemImage: "3.circle", name: "Location", subtitle: "Where the machine will store ?", content: AnyView(CreatePhaseChooseSaveDirectoryView())),
            CreateStepperGuideItem(systemImage: "4.circle", name: "System Image", subtitle: "Download or choose ipsw/iso file ?", content: AnyView(CreatePhaseChooseSystemImage())),
            CreateStepperGuideItem(systemImage: "5.circle", name: "Configuration", subtitle: "Config virtual devices such as size of disk, network type...", content: AnyView(CreatePhaseConfigurationView())),
            CreateStepperGuideItem(systemImage: "6.circle", name: "Creating", subtitle: "Start creating virtual machines...", content: AnyView(CreatePhaseCreatingView())),
            CreateStepperGuideItem(systemImage: "7.circle", name: "Completion", subtitle: "Congratulations", content: AnyView(CreatePhaseCompleteView())),
        ]
        
        self.state.stepCount = self.steps.count
    }
    
    var body: some View {
        HStack(alignment:.top) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(0..<steps.count, id: \.self) { index in
                    CreateStepperGuideStepItemView(systemImage: steps[index].systemImage, name: steps[index].name, subtitle: steps[index].subtitle, pointing: index == state.current)
                }
                Spacer()
            }
            .frame(width: 160)
            .padding()
            
            CreateStepperGuideSeparatorView()
            
            VStack {
                ZStack {
                    ForEach(0..<steps.count, id: \.self) { index in
                        steps[index].content
                            .opacity(index == state.current ? 1 : 0)
                    }
                }
                
                Spacer()
                
                HStack {
                    Spacer()
                    
                    if state.isPreviousAvaliable() {
                        Button {
                            state.movePreviousStep()
                        } label: {
                            Image(systemName: "chevron.backward.2")
                            Text(state.getPreviousButtonText())
                                .frame(width: 60)
                        }
                    }
                    
                    Button {
                        state.moveNextStep()
                    } label: {
                        Text(state.getNextButtonText())
                            .frame(width: 60)
                        Image(systemName: "chevron.forward.2")
                    }
                }
            }
            .padding()
        }
    }
}

struct CreateStepperGuideView_Previews: PreviewProvider {
    static var previews: some View {
        CreateStepperGuideView()
            .frame(width: 600, height: 400)
    }
}
