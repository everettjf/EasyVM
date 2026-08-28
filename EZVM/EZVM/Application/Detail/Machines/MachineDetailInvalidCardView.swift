//
//  MachineDetailInvalidCardView.swift
//  EZVM
//
//  Created by everettjf on 2022/10/3.
//

import SwiftUI

#if arch(arm64)
struct MachineDetailInvalidCardView: View {
    let item: HomeItemVMModel
    let onRemove: () -> Void
    
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.title)
                .foregroundStyle(.secondary)
            Text("Machine Not Found")
                .font(.title3.weight(.semibold))
            Text(item.rootPath.path(percentEncoded: false))
                .font(.caption)
                .lineLimit(5)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            Spacer()

            Button(role: .destructive, action: onRemove) {
                Label("Remove from List", systemImage: "minus.circle")
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("invalid-machine.remove")
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 350, alignment: .top)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(.separator.opacity(0.45), lineWidth: 1)
        }
    }
}

//struct MachineDetailInvalidCardView_Previews: PreviewProvider {
//    static var previews: some View {
//        MachineDetailInvalidCardView()
//    }
//}

#endif
