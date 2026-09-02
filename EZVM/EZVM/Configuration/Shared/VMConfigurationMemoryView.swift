import SwiftUI

#if arch(arm64)
struct VMConfigurationMemoryView: View {
    @Environment(VMConfigurationViewStateObject.self) private var configData
    private let gibibyte = UInt64(1_073_741_824)

    var body: some View {
        LabeledContent("Memory") {
            VStack(alignment: .trailing, spacing: 7) {
                HStack(spacing: 12) {
                    Slider(value: memoryBinding, in: minimumGiB...maximumGiB, step: 0.5).frame(minWidth: 240)
                    Text(memoryLabel).font(.body.monospacedDigit().weight(.semibold)).frame(width: 64, alignment: .trailing)
                }
                HStack(spacing: 8) {
                    Text("Host: \(hostMemoryGiB, format: .number.precision(.fractionLength(0))) GB")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(recommendedValues, id: \.self) { value in
                        Button("\(value, format: .number.precision(.fractionLength(value.rounded() == value ? 0 : 1))) GB") {
                            memoryBinding.wrappedValue = value
                        }.buttonStyle(.borderless).controlSize(.small)
                    }
                }
                if memoryBinding.wrappedValue > hostMemoryGiB * 0.75 {
                    Label("This leaves little memory for macOS and may cause heavy swapping.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var memoryBinding: Binding<Double> {
        Binding(get: { Double(configData.memorySize) / Double(gibibyte) }, set: { configData.memorySize = UInt64($0 * Double(gibibyte)) })
    }
    private var minimumGiB: Double { Double(VMModelFieldMemory.minSize()) / Double(gibibyte) }
    private var maximumGiB: Double { Double(VMModelFieldMemory.maxSize()) / Double(gibibyte) }
    private var hostMemoryGiB: Double { Double(ProcessInfo.processInfo.physicalMemory) / Double(gibibyte) }
    private var memoryLabel: String {
        memoryBinding.wrappedValue.formatted(.number.precision(.fractionLength(memoryBinding.wrappedValue.rounded() == memoryBinding.wrappedValue ? 0 : 1))) + " GB"
    }
    private var recommendedValues: [Double] { [4, 8, 16].filter { $0 >= minimumGiB && $0 <= maximumGiB } }
}
#endif
