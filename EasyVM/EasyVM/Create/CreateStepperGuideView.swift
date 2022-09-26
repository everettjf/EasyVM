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

class CreateStepperGuideStateObject: ObservableObject {
    @Published var current: Int
    @Published var stepCount: Int
    
    init(stepCount: Int) {
        self.current = 0
        self.stepCount = stepCount
    }
    
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
    @ObservedObject var formData: CreateFormModel
    @ObservedObject var stepperState: CreateStepperGuideStateObject
    
    let steps: [CreateStepperGuideItem]
    
    init() {
        let steps = [
            CreateStepperGuideItem(
                systemImage: "1.circle",
                name: "OS Type",
                subtitle: "Create macOS or Linux ?",
                content: AnyView(CreatePhaseSystemTypeView())),
            CreateStepperGuideItem(
                systemImage: "2.circle",
                name: "Name",
                subtitle: "Name the machine",
                content: AnyView(CreatePhaseNameConfigView())),
            CreateStepperGuideItem(
                systemImage: "3.circle",
                name: "Location",
                subtitle: "Where the machine will store ?",
                content: AnyView(CreatePhaseSaveDirectoryView())),
            CreateStepperGuideItem(
                systemImage: "4.circle",
                name: "System Image",
                subtitle: "Download or choose ipsw/iso file ?",
                content: AnyView(CreatePhaseSystemImageView())),
            CreateStepperGuideItem(
                systemImage: "5.circle",
                name: "Configuration",
                subtitle: "Config virtual devices such as size of disk, network type...",
                content: AnyView(CreatePhaseConfigurationView())),
            CreateStepperGuideItem(
                systemImage: "6.circle",
                name: "Creating",
                subtitle: "Start creating virtual machines...",
                content: AnyView(CreatePhaseCreatingView())),
            CreateStepperGuideItem(
                systemImage: "7.circle",
                name: "Completion",
                subtitle: "Congratulations",
                content: AnyView(CreatePhaseCompleteView())),
        ]
        
        self.steps = steps
        self.formData = CreateFormModel()
        self.stepperState = CreateStepperGuideStateObject(stepCount: steps.count)
    }
    
    var body: some View {
        content
            .environmentObject(formData)
            .environmentObject(stepperState)
    }
    
    var content: some View {
        HStack(alignment:.top) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(0..<steps.count, id: \.self) { index in
                    CreateStepperGuideStepItemView(systemImage: steps[index].systemImage, name: steps[index].name, subtitle: steps[index].subtitle, pointing: index == stepperState.current)
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
                            .opacity(index == stepperState.current ? 1 : 0)
                    }
                }
                
                Spacer()
                
                HStack {
                    Spacer()
                    
                    if stepperState.isPreviousAvaliable() {
                        Button {
                            stepperState.movePreviousStep()
                        } label: {
                            Image(systemName: "chevron.backward.2")
                            Text(stepperState.getPreviousButtonText())
                                .frame(width: 60)
                        }
                    }
                    
                    Button {
                        stepperState.moveNextStep()
                    } label: {
                        Text(stepperState.getNextButtonText())
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
