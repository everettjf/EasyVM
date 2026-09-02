import SwiftUI

#if arch(arm64)
struct VMConfigurationCPUView: View {
    @Environment(VMConfigurationViewStateObject.self) private var configData

    var body: some View {
        LabeledContent("Processors") {
            VStack(alignment: .trailing, spacing: 7) {
                HStack(spacing: 12) {
                    Slider(value: Binding(
                        get: { Double(configData.cpuCount) },
                        set: { configData.cpuCount = Int($0.rounded()) }
                    ), in: Double(VMModelFieldCPU.minCount())...Double(VMModelFieldCPU.maxCount()), step: 1)
                    .frame(minWidth: 240)
                    Text("\(configData.cpuCount)").font(.body.monospacedDigit().weight(.semibold)).frame(width: 34)
                }
                Text("Host: \(ProcessInfo.processInfo.activeProcessorCount) logical processors")
                    .font(.caption).foregroundStyle(.secondary)
                if configData.cpuCount > recommendedMaximum {
                    Label("Leaving processors for macOS keeps the VM and host responsive.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var recommendedMaximum: Int {
        max(2, Int(Double(ProcessInfo.processInfo.activeProcessorCount) * 0.75))
    }
}
#endif
