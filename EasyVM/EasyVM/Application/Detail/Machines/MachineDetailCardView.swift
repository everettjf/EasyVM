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
    let isRunning: Bool

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
        .frame(height: 120)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay(alignment: .topTrailing) {
            if isRunning {
                HStack(spacing: 4) {
                    Circle()
                        .fill(.green)
                        .frame(width: 7, height: 7)
                    Text("Running")
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

    @ObservedObject private var runningRegistry = VMRunningRegistry.shared

    var snapshotCount: Int {
        VMSnapshotManager.snapshotCount(vmRootPath: model.rootPath)
    }

    var isRunning: Bool {
        runningRegistry.isRunning(rootPath: model.rootPath)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(model.config.name)
                    .font(.headline)
                Spacer()
                Text(model.config.type == .linux ? "Linux" : "macOS")
                    .font(.footnote)
                    .fontWeight(.bold)
                    .padding(3)
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .stroke(.gray, lineWidth: 1)
                    )
            }
            
            MachineThumbnailView(model: model, isRunning: isRunning)


            Group {
                HStack(spacing: 2) {
                    Image(systemName: "doc.viewfinder.fill")
                    Text("Disk: \(model.displayDiskInfo)")
                }
                .font(.caption2)
                HStack(spacing: 2) {
                    Image(systemName: "cpu")
                    Text("CPU: \(model.config.cpu.count)")
                }
                .font(.caption2)
                HStack(spacing: 2) {
                    Image(systemName: "memorychip")
                    Text("Memory: \(model.displayMemoryInfo)")
                }
                .font(.caption2)
                
                HStack(alignment: .top, spacing: 2) {
                    Image(systemName: "circle.hexagonpath")
                    Text("Attributes: \(model.displayAttributeInfo)")
                        .lineLimit(3)
                }
                .font(.caption2)
                
                if !model.config.remark.isEmpty {
                    HStack(alignment: .top, spacing: 2) {
                        Image(systemName: "captions.bubble")
                        Text("Description: \(model.config.remark)")
                            .lineLimit(3)
                    }
                    .font(.caption2)
                }
            }

            Spacer()

            HStack {
                Button {
                    action.onPlay()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: isRunning ? "macwindow" : "play")
                        Text(isRunning ? "Open" : "Run")
                    }
                    .fontWeight(.bold)
                }
                .buttonStyle(.borderless)


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

                Button {
                    action.onEdit()
                } label: {
                    Image(systemName: "slider.vertical.3")
                }
                .buttonStyle(.borderless)

            }
        }
        .padding(.all, 10)
        .frame(width: 230, height: 330)
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .stroke(.gray, lineWidth: 1)
        )
        .padding(.all, 5)
    }
}

#endif
