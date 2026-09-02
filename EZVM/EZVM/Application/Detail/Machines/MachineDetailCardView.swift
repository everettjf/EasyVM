//
//  MachineDetailCardView.swift
//  EZVM
//
//  Created by everettjf on 2022/9/4.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers


#if arch(arm64)
struct MachineDetailCardAction {
    let onPlay: () -> Void
    let onEdit: () -> Void
    let onSnapshots: () -> Void
    let onRemove: () -> Void
}

enum VMGeneratedThumbnailStyle: String, CaseIterable, Identifiable {
    case aurora, midnight, ocean, sunset, graphite, paper, terminal, editorial, neon, mono

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
            case .aurora:
                titleText(.system(size: 46, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .shadow(color: .purple.opacity(0.45), radius: 16)
            case .midnight:
                titleText(.system(size: 43, weight: .semibold, design: .rounded)).foregroundStyle(.white)
            case .ocean:
                titleText(.system(size: 46, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
                    .shadow(color: .blue.opacity(0.7), radius: 14)
            case .sunset:
                titleText(.system(size: 44, weight: .heavy, design: .rounded)).foregroundStyle(.white)
            case .graphite:
                titleText(.system(size: 42, weight: .medium, design: .default)).foregroundStyle(.white.opacity(0.92))
            case .paper:
                VStack(spacing: 6) {
                    titleText(.system(size: 44, weight: .bold, design: .serif)).foregroundStyle(Color(red: 0.16, green: 0.15, blue: 0.14))
                    Rectangle().fill(Color.orange).frame(width: 42, height: 3)
                }
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
            case .neon:
                ZStack {
                    titleText(.system(size: 46, weight: .black, design: .monospaced)).foregroundStyle(.pink).offset(x: 3, y: 2)
                    titleText(.system(size: 46, weight: .black, design: .monospaced)).foregroundStyle(.cyan).offset(x: -2, y: -1)
                    titleText(.system(size: 46, weight: .black, design: .monospaced)).foregroundStyle(.white)
                }
            case .mono:
                VStack(alignment: .leading, spacing: 8) {
                    Text(type == .linux ? "LINUX" : "MACOS").font(.caption.monospaced().weight(.bold)).tracking(3)
                    titleText(.system(size: 45, weight: .black, design: .default))
                }.foregroundStyle(.white).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var background: some View {
        LinearGradient(
            colors: palette,
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var palette: [Color] {
        switch style {
        case .aurora: [.indigo, .purple, .blue]
        case .midnight: [Color(red: 0.03, green: 0.05, blue: 0.11), Color(red: 0.10, green: 0.14, blue: 0.24)]
        case .ocean: [Color(red: 0.02, green: 0.28, blue: 0.48), Color(red: 0.05, green: 0.65, blue: 0.70)]
        case .sunset: [Color(red: 0.94, green: 0.27, blue: 0.30), Color(red: 0.98, green: 0.60, blue: 0.24)]
        case .graphite: [Color(red: 0.12, green: 0.13, blue: 0.15), Color(red: 0.34, green: 0.36, blue: 0.40)]
        case .paper: [Color(red: 0.98, green: 0.95, blue: 0.88), Color(red: 0.91, green: 0.86, blue: 0.76)]
        case .terminal: [Color(red: 0.02, green: 0.04, blue: 0.04), Color(red: 0.04, green: 0.10, blue: 0.08)]
        case .editorial: [Color(red: 0.19, green: 0.08, blue: 0.12), Color(red: 0.48, green: 0.17, blue: 0.19)]
        case .neon: [Color(red: 0.06, green: 0.02, blue: 0.16), Color(red: 0.16, green: 0.03, blue: 0.25)]
        case .mono: [Color.black, Color(red: 0.18, green: 0.18, blue: 0.18)]
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
    @AppStorage private var generatedStyleRaw: String

    init(model: VMModel, runPhase: VMRunPhase?) {
        self.model = model
        self.runPhase = runPhase
        _generatedStyleRaw = AppStorage(wrappedValue: "", VMThumbnailPreferences.generatedStyleKey(for: model.rootPath))
    }

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
                    style: effectiveGeneratedStyle
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
        .contextMenu {
            Menu("Cover Style", systemImage: "paintpalette") {
                Picker("Cover Style", selection: $generatedStyleRaw) {
                    Text("App Default").tag("")
                    Divider()
                    ForEach(VMGeneratedThumbnailStyle.allCases) { style in
                        Text(style.title).tag(style.rawValue)
                    }
                }
            }
        }
        .help("Right-click to choose this virtual machine’s cover style")
    }

    private var effectiveGeneratedStyle: VMGeneratedThumbnailStyle {
        if let style = VMGeneratedThumbnailStyle(rawValue: generatedStyleRaw) { return style }
        let appDefault = UserDefaults.standard.string(forKey: VMThumbnailPreferences.generatedStyleKey)
        return VMGeneratedThumbnailStyle(rawValue: appDefault ?? "") ?? .aurora
    }
}

struct MachineDetailCardView: View {

    let item: HomeItemVMModel
    let model: VMModel
    let action: MachineDetailCardAction

    @State private var runningRegistry = VMRunningRegistry.shared
    @State private var isDropTargeted = false
    @State private var shareFeedback: String?

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
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.accentColor.opacity(0.14))
                    .overlay {
                        Label("Drop folders to share", systemImage: "folder.fill.badge.plus")
                            .font(.headline)
                            .padding(14)
                            .background(.regularMaterial, in: Capsule())
                    }
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            addSharedFolders(urls)
        } isTargeted: {
            isDropTargeted = $0
        }
        .alert("Shared Folder", isPresented: Binding(
            get: { shareFeedback != nil },
            set: { if !$0 { shareFeedback = nil } }
        )) {
            Button("OK") { shareFeedback = nil }
        } message: {
            Text(shareFeedback ?? "")
        }
    }

    private func addSharedFolders(_ urls: [URL]) -> Bool {
        let directories = VMSharedFolderDrop.directories(from: urls)
        guard !directories.isEmpty else {
            shareFeedback = "Only folders can be shared with a virtual machine."
            return false
        }
        let state = VMConfigurationViewStateObject(configModel: model.config)
        let added = directories.reduce(into: 0) { count, url in
            if state.addSharedDirectory(url) { count += 1 }
        }
        guard added > 0 else {
            shareFeedback = "Those folders are already shared."
            return false
        }
        switch state.getConfigModel().writeConfigToFile(path: model.configURL) {
        case .success:
            NotificationCenter.default.post(name: AppConfigManager.newVMChangedNotification, object: nil)
            shareFeedback = "Added \(added) shared folder\(added == 1 ? "" : "s"). Changes apply after the next start."
            return true
        case .failure(let error):
            shareFeedback = "EZVM could not add the shared folders: \(error)"
            return false
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
