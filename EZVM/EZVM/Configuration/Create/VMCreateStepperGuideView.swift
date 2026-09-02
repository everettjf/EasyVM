import SwiftUI
import Observation

#if arch(arm64)

private struct VMCreateGuideProgressView: View {
    let steps: [VMCreateStepperGuideItem]
    let currentStepID: UUID?
    let completedStepIDs: Set<UUID>

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                if index > 0 {
                    Rectangle()
                        .fill(completedStepIDs.contains(step.id) ? Color.green : Color.secondary.opacity(0.22))
                        .frame(height: 1)
                        .accessibilityHidden(true)
                }

                VStack(spacing: 5) {
                    ZStack {
                        Circle()
                            .fill(circleColor(for: step.id))
                            .frame(width: 14, height: 14)
                        if completedStepIDs.contains(step.id) {
                            Image(systemName: "checkmark")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(.white)
                        }
                    }
                    Text(step.name)
                        .font(.caption2)
                        .foregroundStyle(step.id == currentStepID ? .primary : .secondary)
                        .lineLimit(1)
                }
                .frame(minWidth: 70)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Step \(index + 1) of \(steps.count): \(step.name)")
                .accessibilityValue(accessibilityValue(for: step.id))
                .accessibilityIdentifier("create-guide-progress-\(index + 1)")
            }
        }
    }

    private func circleColor(for id: UUID) -> Color {
        if completedStepIDs.contains(id) { return .green }
        if id == currentStepID { return .accentColor }
        return .secondary.opacity(0.20)
    }

    private func accessibilityValue(for id: UUID) -> String {
        if completedStepIDs.contains(id) { return "Completed" }
        if id == currentStepID { return "Current step" }
        return "Not started"
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
    var secondaryNextTitle: String? = nil
    var autoAdvanceOnSuccess = false
    var participatesInSetupProgress = true
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
            VMCreateStepperGuideItem(systemImage: "slider.horizontal.3", name: "Resources", subtitle: "CPU, memory, and storage", content: AnyView(CreatePhaseConfigurationView()), handler: CreatePhaseConfigurationViewHandler()),
            VMCreateStepperGuideItem(systemImage: "folder", name: "Sharing", subtitle: "Share Mac folders", content: AnyView(CreatePhaseSharingView()), handler: CreatePhaseSharingViewHandler(), secondaryNextTitle: "Not Now"),
            VMCreateStepperGuideItem(systemImage: "checklist", name: "Review", subtitle: "Confirm and create", content: AnyView(CreatePhaseReviewView()), handler: CreatePhaseReviewViewHandler(), nextTitle: "Create"),
            VMCreateStepperGuideItem(systemImage: "arrow.down.circle", name: "Creating", subtitle: "Download and install once", content: AnyView(CreatePhaseCreatingView()), handler: CreatePhaseCreatingViewHandler(), autoAdvanceOnSuccess: true, participatesInSetupProgress: false),
            VMCreateStepperGuideItem(systemImage: "checkmark.seal", name: "Completion", subtitle: "Ready to run", content: AnyView(CreatePhaseCompleteView()), handler: CreatePhaseCompleteViewHandler(), participatesInSetupProgress: false),
        ]
        self.steps = steps
        _stepperState = State(initialValue: VMCreateStepperGuideStateObject(stepCount: steps.count))
        _formData = State(initialValue: VMCreateViewStateObject())
        _configData = State(initialValue: VMConfigurationViewStateObject())
    }

    var body: some View {
        mainContent
        .environment(formData)
        .environment(configData)
        .frame(minWidth: 760, idealWidth: 900, minHeight: 620, idealHeight: 680)
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

    private var mainContent: some View {
        VStack(spacing: 0) {
            steps[stepperState.current].content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 42)
                .padding(.vertical, 28)
            Divider()
            footer
        }
    }

    private var footer: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                Text(stepStatusMessage)
                    .font(.caption)
                    .foregroundStyle(stepFailed ? Color.red : Color.secondary)
                    .lineLimit(2)
                Spacer()
                if stepperState.canMovePrevious && isSetupStep {
                    Button {
                        stepperState.movePreviousStep()
                        disableNext = false
                        stepFailed = false
                        stepStatusMessage = ""
                    } label: {
                        Label("Previous", systemImage: "chevron.left")
                    }
                    .disabled(isStepInitializing || formData.disablePreviousButton)
                    .keyboardShortcut(.leftArrow, modifiers: [.command])
                    .accessibilityIdentifier("create-guide-previous")
                }
                if let secondaryNextTitle = steps[stepperState.current].secondaryNextTitle {
                    Button(secondaryNextTitle) {
                        tryMoveNextStep()
                    }
                    .disabled(isStepInitializing || disableNext)
                    .accessibilityIdentifier("create-guide-secondary-next")
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

            if isSetupStep {
                VMCreateGuideProgressView(
                    steps: setupSteps,
                    currentStepID: steps[stepperState.current].id,
                    completedStepIDs: completedSetupStepIDs
                )
                .frame(maxWidth: 560)
            } else {
                Text(steps[stepperState.current].subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
    }

    private var setupSteps: [VMCreateStepperGuideItem] {
        steps.filter(\.participatesInSetupProgress)
    }

    private var isSetupStep: Bool {
        steps[stepperState.current].participatesInSetupProgress
    }

    private var completedSetupStepIDs: Set<UUID> {
        Set(steps.prefix(stepperState.current).filter(\.participatesInSetupProgress).map(\.id))
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
