import SwiftUI
import Observation

#if arch(arm64)

private struct VMCreateGuideStepRow: View {
    let systemImage: String
    let name: String
    let subtitle: String
    let index: Int
    let currentIndex: Int

    private var isCurrent: Bool { index == currentIndex }
    private var isComplete: Bool { index < currentIndex }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle().fill(circleColor).frame(width: 30, height: 30)
                Image(systemName: isComplete ? "checkmark" : systemImage)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isCurrent || isComplete ? Color.white : Color.secondary)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(name)
                    .font(.callout.weight(isCurrent ? .semibold : .medium))
                    .foregroundStyle(isCurrent ? .primary : .secondary)
                Text(subtitle).font(.caption).foregroundStyle(.tertiary).lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(isCurrent ? Color.accentColor.opacity(0.10) : Color.clear, in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
        .accessibilityValue(isCurrent ? "Current step" : (isComplete ? "Completed" : "Not started"))
    }

    private var circleColor: Color {
        if isCurrent { return .accentColor }
        if isComplete { return .green }
        return .secondary.opacity(0.12)
    }
}

@MainActor
struct VMCreateStepperGuidePhaseContext {
    let formData: VMCreateViewStateObject
    let configData: VMConfigurationViewStateObject
}

@MainActor
protocol VMCreateStepperGuidePhaseHandler {
    func verifyForm(context: VMCreateStepperGuidePhaseContext) -> VMOSResultVoid
    func onStepMovedIn(context: VMCreateStepperGuidePhaseContext) async -> VMOSResultVoid
    func cancel(context: VMCreateStepperGuidePhaseContext)
}

extension VMCreateStepperGuidePhaseHandler {
    func cancel(context: VMCreateStepperGuidePhaseContext) {}
}

struct VMCreateStepperGuideItem: Identifiable {
    let id = UUID()
    let systemImage: String
    let name: String
    let subtitle: String
    let content: AnyView
    let handler: any VMCreateStepperGuidePhaseHandler
    var nextTitle: String? = nil
    var autoAdvanceOnSuccess = false
}

@MainActor
@Observable
final class VMCreateStepperGuideStateObject {
    var current = 0
    let stepCount: Int

    init(stepCount: Int) { self.stepCount = stepCount }

    func moveNextStep() {
        guard current < stepCount - 1 else { return }
        current += 1
    }

    func movePreviousStep() {
        guard current > 0 else { return }
        current -= 1
    }

    var isCompletion: Bool { current == stepCount - 1 }
    var canMovePrevious: Bool { current > 0 }
}

struct VMCreateStepperGuideView: View {
    @State private var stepperState: VMCreateStepperGuideStateObject
    @State private var formData: VMCreateViewStateObject
    @State private var configData: VMConfigurationViewStateObject
    @Environment(\.dismiss) private var dismiss

    @State private var showingAlert = false
    @State private var alertMessage = ""
    @State private var isStepInitializing = false
    @State private var stepStatusMessage = ""
    @State private var disableNext = false
    @State private var stepFailed = false

    let steps: [VMCreateStepperGuideItem]

    init() {
        let steps = [
            VMCreateStepperGuideItem(systemImage: "desktopcomputer", name: "System", subtitle: "Choose OS and image", content: AnyView(CreatePhaseSystemView()), handler: CreatePhaseSystemViewHandler()),
            VMCreateStepperGuideItem(systemImage: "tag", name: "Name & Location", subtitle: "Name and save location", content: AnyView(CreatePhaseNameLocationView()), handler: CreatePhaseNameLocationViewHandler()),
            VMCreateStepperGuideItem(systemImage: "slider.horizontal.3", name: "Configuration", subtitle: "Hardware and devices", content: AnyView(CreatePhaseConfigurationView()), handler: CreatePhaseConfigurationViewHandler(), nextTitle: "Create"),
            VMCreateStepperGuideItem(systemImage: "arrow.down.circle", name: "Creating", subtitle: "Download and install once", content: AnyView(CreatePhaseCreatingView()), handler: CreatePhaseCreatingViewHandler(), autoAdvanceOnSuccess: true),
            VMCreateStepperGuideItem(systemImage: "checkmark.seal", name: "Completion", subtitle: "Ready to run", content: AnyView(CreatePhaseCompleteView()), handler: CreatePhaseCompleteViewHandler()),
        ]
        self.steps = steps
        _stepperState = State(initialValue: VMCreateStepperGuideStateObject(stepCount: steps.count))
        _formData = State(initialValue: VMCreateViewStateObject())
        _configData = State(initialValue: VMConfigurationViewStateObject())
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            mainContent
        }
        .environment(formData)
        .environment(configData)
        .frame(minWidth: 860, idealWidth: 960, minHeight: 600, idealHeight: 660)
        .alert("Unable to Continue", isPresented: $showingAlert) {
            Button("OK") {}
        } message: {
            Text(alertMessage)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(closeButtonTitle) { closeGuide() }
                    .disabled(!canCloseGuide)
                    .accessibilityIdentifier("create-guide-close")
            }
        }
        .onDisappear {
            if formData.canCancelCreation {
                cancelCurrentOperation()
            }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Image(systemName: "shippingbox.fill").font(.title2).foregroundStyle(Color.accentColor)
                Text("New Virtual Machine").font(.title3.weight(.semibold))
                Text("Guided setup for macOS and Linux").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.bottom, 22)

            ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                VMCreateGuideStepRow(systemImage: step.systemImage, name: step.name, subtitle: step.subtitle, index: index, currentIndex: stepperState.current)
            }
            Spacer(minLength: 12)
            Button { closeGuide() } label: {
                Label(closeButtonTitle, systemImage: formData.canCancelCreation ? "stop.fill" : "xmark")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(!canCloseGuide)
            .accessibilityIdentifier("create-guide-sidebar-close")
        }
        .frame(width: 220)
        .padding(20)
        .background(.regularMaterial)
    }

    private var mainContent: some View {
        VStack(spacing: 0) {
            steps[stepperState.current].content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(28)
            Divider()
            footer
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text(stepStatusMessage)
                .font(.caption)
                .foregroundStyle(stepFailed ? Color.red : Color.secondary)
                .lineLimit(2)
            Spacer()
            if stepperState.canMovePrevious {
                Button {
                    stepperState.movePreviousStep()
                    disableNext = false
                    stepFailed = false
                    stepStatusMessage = ""
                } label: {
                    Label("Previous", systemImage: "chevron.left")
                }
                .disabled(isStepInitializing || formData.disablePreviousButton)
            }
            Button {
                if stepFailed { retryCurrentStep() } else { tryMoveNextStep() }
            } label: {
                HStack {
                    Text(nextButtonText)
                    Image(systemName: stepFailed ? "arrow.clockwise" : "chevron.right")
                }
                .frame(minWidth: 90)
            }
            .disabled(isStepInitializing || disableNext)
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("create-guide-next")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    private var nextButtonText: String {
        if stepFailed { return "Retry" }
        if stepperState.isCompletion { return "Close" }
        return steps[stepperState.current].nextTitle ?? "Next"
    }

    private var canCloseGuide: Bool {
        !isStepInitializing || formData.canCancelCreation
    }

    private var closeButtonTitle: String {
        formData.canCancelCreation ? "Cancel Download" : "Close"
    }

    private func closeGuide() {
        if formData.canCancelCreation {
            cancelCurrentOperation()
        }
        dismiss()
    }

    private func cancelCurrentOperation() {
        steps[stepperState.current].handler.cancel(
            context: VMCreateStepperGuidePhaseContext(formData: formData, configData: configData)
        )
    }

    private func tryMoveNextStep() {
        if stepperState.isCompletion { dismiss(); return }
        let context = VMCreateStepperGuidePhaseContext(formData: formData, configData: configData)
        let currentItem = steps[stepperState.current]
        if case .failure(let error) = currentItem.handler.verifyForm(context: context) {
            alertMessage = error
            showingAlert = true
            return
        }
        stepperState.moveNextStep()
        runCurrentStep(context: context)
    }

    private func retryCurrentStep() {
        runCurrentStep(context: VMCreateStepperGuidePhaseContext(formData: formData, configData: configData))
    }

    private func runCurrentStep(context: VMCreateStepperGuidePhaseContext) {
        let item = steps[stepperState.current]
        isStepInitializing = true
        stepFailed = false
        disableNext = true
        stepStatusMessage = ""

        Task { @MainActor in
            let result = await item.handler.onStepMovedIn(context: context)
            isStepInitializing = false
            if case .failure(let error) = result {
                stepStatusMessage = error
                stepFailed = true
                disableNext = false
                return
            }
            disableNext = false
            if item.autoAdvanceOnSuccess && !stepperState.isCompletion {
                stepperState.moveNextStep()
                let followingResult = await steps[stepperState.current].handler.onStepMovedIn(context: context)
                if case .failure(let error) = followingResult { stepStatusMessage = error }
            }
        }
    }
}

struct VMCreateStepperGuideView_Previews: PreviewProvider {
    static var previews: some View {
        VMCreateStepperGuideView().frame(width: 960, height: 660)
    }
}

#endif
