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

struct CreateStepperGuidePhaseContext {
    let formData: CreateFormStateObject
    let configData: VMConfigurationViewStateObject
}

protocol CreateStepperGuidePhaseHandler {
    func verifyForm(context: CreateStepperGuidePhaseContext) -> VMOSResultVoid
    func onStepMovedIn(context: CreateStepperGuidePhaseContext) async -> VMOSResultVoid
}

struct CreateStepperGuideItem : Identifiable {
    let id = UUID()
    let systemImage: String
    let name: String
    let subtitle: String
    let content: AnyView
    let handler: any CreateStepperGuidePhaseHandler
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
    @ObservedObject var formData: CreateFormStateObject
    @ObservedObject var stepperState: CreateStepperGuideStateObject
    @ObservedObject var configData: VMConfigurationViewStateObject
    
    @Environment(\.presentationMode) var presentationMode
    
    @State var showingAlert = false
    @State var alertMessage = ""
    
    @State var isStepInitializing = false
    @State var stepStatusMessage = ""
    @State var disableNext = false
    
    let steps: [CreateStepperGuideItem]
    
    init() {
        let steps = [
            CreateStepperGuideItem(
                systemImage: "1.circle",
                name: "OS Type",
                subtitle: "Create macOS or Linux ?",
                content: AnyView(CreatePhaseSystemTypeView()),
                handler: CreatePhaseSystemTypeViewHandler()
            ),
            CreateStepperGuideItem(
                systemImage: "2.circle",
                name: "Name",
                subtitle: "Name the machine",
                content: AnyView(CreatePhaseNameConfigView()),
                handler: CreatePhaseNameConfigViewHandler()
            ),
            CreateStepperGuideItem(
                systemImage: "3.circle",
                name: "Location",
                subtitle: "Where the machine will store ?",
                content: AnyView(CreatePhaseSaveDirectoryView()),
                handler: CreatePhaseSaveDirectoryViewHandler()
            ),
            CreateStepperGuideItem(
                systemImage: "4.circle",
                name: "System Image",
                subtitle: "Download or choose ipsw/iso file ?",
                content: AnyView(CreatePhaseSystemImageView()),
                handler: CreatePhaseSystemImageViewHandler()
            ),
            CreateStepperGuideItem(
                systemImage: "5.circle",
                name: "Configuration",
                subtitle: "Config virtual devices such as size of disk, network type...",
                content: AnyView(CreatePhaseConfigurationView()),
                handler: CreatePhaseConfigurationViewHandler()
            ),
            CreateStepperGuideItem(
                systemImage: "6.circle",
                name: "Creating",
                subtitle: "Start creating virtual machines...",
                content: AnyView(CreatePhaseCreatingView()),
                handler: CreatePhaseCreatingViewHandler()
            ),
            CreateStepperGuideItem(
                systemImage: "7.circle",
                name: "Completion",
                subtitle: "Congratulations",
                content: AnyView(CreatePhaseCompleteView()),
                handler: CreatePhaseCompleteViewHandler()
            ),
        ]
        
        self.steps = steps
        self.formData = CreateFormStateObject()
        self.configData = VMConfigurationViewStateObject()
        self.stepperState = CreateStepperGuideStateObject(stepCount: steps.count)
    }
    
    var body: some View {
        content
            .environmentObject(formData)
            .environmentObject(configData)
            .environmentObject(stepperState)
            .alert("Tips", isPresented: $showingAlert) {
                Button {
                    showingAlert.toggle()
                } label: {
                    Text("OK")
                }
            } message: {
                Text(alertMessage)
            }

    }
    
    var content: some View {
        HStack(alignment:.top) {
            // body
            VStack(alignment: .leading, spacing: 0) {
                ForEach(0..<steps.count, id: \.self) { index in
                    CreateStepperGuideStepItemView(systemImage: steps[index].systemImage, name: steps[index].name, subtitle: steps[index].subtitle, pointing: index == stepperState.current)
                }
                Spacer()
            }
            .frame(width: 160)
            .padding()

            // bottom
            CreateStepperGuideSeparatorView()
            
            bottom
        }
    }
    
    var bottom: some View {
        
        VStack {
            ZStack {
                ForEach(0..<steps.count, id: \.self) { index in
                    steps[index].content
                        .opacity(index == stepperState.current ? 1 : 0)
                }
            }
            
            Spacer()
            
            HStack {
                Text(stepStatusMessage)
                    .font(.caption)
                
                Spacer()
                
                if stepperState.isPreviousAvaliable() {
                    Button {
                        stepperState.movePreviousStep()
                        disableNext = false
                    } label: {
                        Image(systemName: "chevron.backward.2")
                        Text(stepperState.getPreviousButtonText())
                            .frame(width: 60)
                    }
                    .disabled(isStepInitializing || formData.disablePreviousButton)
                }
                
                Button {
                    tryMoveNextStep()
                } label: {
                    Text(stepperState.getNextButtonText())
                        .frame(width: 60)
                    Image(systemName: "chevron.forward.2")
                }
                .disabled(isStepInitializing || disableNext)
            }
        }
        .padding()
    }
    
    
    func tryMoveNextStep() {
        if stepperState.isStepCompletion() {
            // done , notify main list
            // TODO
            // close
            presentationMode.wrappedValue.dismiss()
            return
        }
        
        let context = CreateStepperGuidePhaseContext(formData: formData, configData: configData)
        let currentItem = steps[stepperState.current]
        let verifyResult = currentItem.handler.verifyForm(context: context)
        if case let .failure(error) = verifyResult {
            showAlert(error)
            return
        }
        
        stepperState.moveNextStep()
        
        let nextItem = steps[stepperState.current]
        // disable button
        self.isStepInitializing = true
        self.stepStatusMessage = ""
        self.disableNext = true
        
        // call onStepMovedIn
        Task {
            let result = await nextItem.handler.onStepMovedIn(context: context)

            DispatchQueue.main.async {
                // enable button
                self.isStepInitializing = false
                
                if case let .failure(error) = result {
                    self.stepStatusMessage = error
                    self.disableNext = true
                } else {
                    self.disableNext = false
                }
            }
        }
    }
    
    func showAlert(_ message: String) {
        alertMessage = message
        showingAlert.toggle()
    }
}

struct CreateStepperGuideView_Previews: PreviewProvider {
    static var previews: some View {
        CreateStepperGuideView()
            .frame(width: 600, height: 400)
    }
}
