//
//  MachineDetailCardView.swift
//  EZVM
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
    let onRemove: () -> Void
}

enum VMGeneratedThumbnailStyle: String, CaseIterable, Identifiable {
    case arcade
    case rounded
    case terminal
    case editorial

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

struct GeneratedMachineThumbnailView: View {
    let title: String
    let type: VMOSType
    let style: VMGeneratedThumbnailStyle

    var body: some View {
        ZStack {
            background
            switch style {
            case .arcade:
                arcadeTitle
            case .rounded:
                titleText(.system(size: 46, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
                    .shadow(color: .blue.opacity(0.7), radius: 14)
            case .terminal:
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 5) {
                        Circle().fill(.red).frame(width: 7, height: 7)
                        Circle().fill(.yellow).frame(width: 7, height: 7)
                        Circle().fill(.green).frame(width: 7, height: 7)
                    }
                    titleText(.system(size: 38, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color(red: 0.45, green: 1, blue: 0.62))
                    Text("$ ezvm run")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.4))
                }
                .padding(22)
                .frame(maxWidth: .infinity, alignment: .leading)
            case .editorial:
                VStack(spacing: 5) {
                    Text(type == .linux ? "LINUX VIRTUAL MACHINE" : "MAC VIRTUAL MACHINE")
                        .font(.system(size: 9, weight: .semibold, design: .serif))
                        .tracking(2.4)
                        .foregroundStyle(.white.opacity(0.55))
                    titleText(.system(size: 48, weight: .bold, design: .serif))
                        .foregroundStyle(.white)
                }
            }
        }
    }

    private var background: some View {
        LinearGradient(
            colors: style == .arcade
                ? [Color(red: 0.07, green: 0.08, blue: 0.13), Color(red: 0.11, green: 0.12, blue: 0.18)]
                : (type == .linux ? [Color(red: 0.08, green: 0.12, blue: 0.18), Color(red: 0.12, green: 0.19, blue: 0.25)] : [.indigo, .blue]),
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var arcadeTitle: some View {
        ZStack {
            titleText(.system(size: 46, weight: .black, design: .monospaced))
                .foregroundStyle(Color.cyan.opacity(0.9))
                .offset(x: -3, y: 3)
            titleText(.system(size: 46, weight: .black, design: .monospaced))
                .foregroundStyle(Color(red: 0.65, green: 0.86, blue: 0.38))
        }
    }

    private func titleText(_ font: Font) -> some View {
        Text(title.uppercased())
            .font(font)
            .lineLimit(1)
            .minimumScaleFactor(0.35)
            .padding(.horizontal, 22)
    }
}

/*
 Thumbnail area of a machine card: shows a bundled, selected, or captured
 image when available, otherwise a generated title cover, with a live
 running badge on top.
 */
struct MachineThumbnailView: View {
    let model: VMModel
    let runPhase: VMRunPhase?
    @AppStorage(VMThumbnailPreferences.generatedStyleKey) private var generatedStyleRaw = VMGeneratedThumbnailStyle.arcade.rawValue

    var body: some View {
        ZStack {
            // Decode the file contents for every notified refresh. Loading by
            // URL can reuse an NSImage representation after the same file has
            // been atomically replaced by the running VM.
            if let data = try? Data(contentsOf: model.screenshotURL),
               let image = NSImage(data: data) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                GeneratedMachineThumbnailView(
                    title: model.config.name,
                    type: model.config.type,
                    style: VMGeneratedThumbnailStyle(rawValue: generatedStyleRaw) ?? .arcade
                )
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
