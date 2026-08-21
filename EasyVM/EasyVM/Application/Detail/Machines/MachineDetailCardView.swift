//
//  MachineDetailCardView.swift
//  EasyVM
//
//  Created by everettjf on 2022/9/4.
//

import SwiftUI
import AppKit


#if arch(arm64)
struct MachineDetailCardAction {
    let onPlay: () -> Void
    let onEdit: () -> Void
    let onSnapshots: () -> Void
}

/*
 Thumbnail area of a machine card: shows the latest screenshot captured
 from the running system when available, otherwise an OS themed
 placeholder, with a live running badge on top.
 */
struct MachineThumbnailView: View {
    let model: VMModel
    let runPhase: VMRunPhase?

    var body: some View {
        ZStack {
            if let image = NSImage(contentsOf: model.screenshotURL) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                LinearGradient(
                    colors: model.config.type == .macOS ? [Color.blue, Color.indigo] : [Color.orange, Color.pink],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                Image(systemName: model.config.type == .macOS ? "macpro.gen3" : "pc")
                    .font(.system(size: 54))
                    .foregroundStyle(.white.opacity(0.35))
            }
        }
        .frame(height: 154)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(alignment: .topTrailing) {
            if let runPhase {
                HStack(spacing: 4) {
                    Circle()
                        .fill(runPhase == .stopping ? .orange : .green)
                        .frame(width: 7, height: 7)
                    Text(runPhase.cardLabel)
                        .font(.caption2)
                        .fontWeight(.semibold)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(.black.opacity(0.55), in: Capsule())
                .foregroundStyle(.white)
                .padding(6)
            }
        }
    }
}

struct MachineDetailCardView: View {

    let item: HomeItemVMModel
    let model: VMModel
    let action: MachineDetailCardAction

    @State private var runningRegistry = VMRunningRegistry.shared

    var snapshotCount: Int {
        VMSnapshotManager.snapshotCount(vmRootPath: model.rootPath)
    }

    var isRunning: Bool {
        runningRegistry.isRunning(rootPath: model.rootPath)
    }

    var runPhase: VMRunPhase? {
        runningRegistry.phase(rootPath: model.rootPath)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.config.name)
                        .font(.title3.weight(.semibold))
                        .lineLimit(1)
                    Text(model.config.type == .linux ? "Linux virtual machine" : "macOS virtual machine")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: model.config.type == .linux ? "pc" : "macpro.gen3")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
            
            MachineThumbnailView(model: model, runPhase: runPhase)


            HStack(spacing: 18) {
                MachineMetric(icon: "cpu", value: "\(model.config.cpu.count)", label: "CPU")
                MachineMetric(icon: "memorychip", value: model.displayMemoryInfo, label: "Memory")
                MachineMetric(icon: "internaldrive", value: model.displayDiskInfo, label: "Disk")
            }

            Spacer()

            HStack(spacing: 8) {
                Button {
                    action.onPlay()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: runPhase == .stopping ? "arrow.down.circle" : (isRunning ? "macwindow" : "play"))
                        Text(runPhase == .stopping ? "Saving…" : (isRunning ? "Open" : "Run"))
                    }
                    .fontWeight(.bold)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityIdentifier("machine.primary-action")
                .disabled(runPhase == .stopping)


                Spacer()
                Button {
                    action.onSnapshots()
                } label: {
                    HStack(spacing: 2) {
                        Image(systemName: "camera.on.rectangle")
                        if snapshotCount > 0 {
                            Text("\(snapshotCount)")
                                .font(.caption)
                        }
                    }
                }
                .buttonStyle(.borderless)
                .help("Snapshots")
                .accessibilityLabel("Snapshots")

                Button {
                    action.onEdit()
                } label: {
                    Image(systemName: "slider.vertical.3")
                }
                .buttonStyle(.borderless)
                .help("Settings")
                .accessibilityLabel("Settings")

            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 350, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(.separator.opacity(0.45), lineWidth: 1)
        }
    }
}

private struct MachineMetric: View {
    let icon: String
    let value: String
    let label: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(value)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

#endif
