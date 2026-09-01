//
//  MacKitUtil.swift
//  ScriptWidgetMac
//
//  Created by everettjf on 2022/1/25.
//

import Foundation
import AppKit
import SwiftUI
import OSLog
import Darwin

enum EZVMLog {
    static let lifecycle = Logger(subsystem: "com.everettjf.ezvm", category: "lifecycle")
    static let storage = Logger(subsystem: "com.everettjf.ezvm", category: "storage")
    static let download = Logger(subsystem: "com.everettjf.ezvm", category: "download")
    static let network = Logger(subsystem: "com.everettjf.ezvm", category: "network")
    static let graphics = Logger(subsystem: "com.everettjf.ezvm", category: "graphics")
    static let input = Logger(subsystem: "com.everettjf.ezvm", category: "input")

    static func info(_ message: String, logger: Logger = lifecycle) {
        logger.info("\(message, privacy: .public)")
    }

    static func error(_ message: String, logger: Logger = lifecycle) {
        logger.error("\(message, privacy: .public)")
    }
}

@MainActor
enum EZVMDiagnostics {
    static func export() throws -> URL {
        let panel = NSSavePanel()
        panel.title = "Export EZVM Diagnostics"
        panel.nameFieldStringValue = "EZVM-Diagnostics-\(ISO8601DateFormatter().string(from: Date()).prefix(10)).txt"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let destination = panel.url else {
            throw CocoaError(.userCancelled)
        }

        var sections = [
            "# EZVM diagnostics",
            AppInfo.diagnosticText,
            "Architecture: \(ProcessInfo.processInfo.machineHardwareName)",
            "Processor count: \(ProcessInfo.processInfo.processorCount)",
            "Physical memory: \(ByteCountFormatter.string(fromByteCount: Int64(ProcessInfo.processInfo.physicalMemory), countStyle: .memory))",
            "Generated: \(Date().formatted(.iso8601))",
            "",
            "# Registered virtual machines"
        ]
        for path in sharedAppConfigManager.appConfig.rootPaths {
            let url = URL(fileURLWithPath: path)
            let config = url.appending(path: "config.json")
            sections.append("\n## \(url.lastPathComponent)\nPath: \(path)")
            if let data = try? Data(contentsOf: config),
               let value = String(data: data, encoding: .utf8) {
                sections.append(value)
            } else {
                sections.append("Configuration unavailable")
            }
        }
        sections.append("\n# Recent EZVM logs")
        if let store = try? OSLogStore(scope: .currentProcessIdentifier) {
            let position = store.position(date: Date().addingTimeInterval(-3600))
            if let entries = try? store.getEntries(at: position) {
                for case let entry as OSLogEntryLog in entries where entry.subsystem == "com.everettjf.ezvm" {
                    sections.append("\(entry.date.formatted(.iso8601)) [\(entry.category)] \(entry.composedMessage)")
                }
            }
        }
        try sections.joined(separator: "\n").write(to: destination, atomically: true, encoding: .utf8)
        return destination
    }
}

private extension ProcessInfo {
    var machineHardwareName: String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var chars = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &chars, &size, nil, 0)
        return String(cString: chars)
    }
}

public class MacKitUtil {
    
    public static func openUrl(_ strURL: String) {
        guard let url = URL(string: strURL) else { return }
        NSWorkspace.shared.open(url)
    }
    
    public static func revealInFinder(_ path: String) {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
    }
    
    public static func toggleSidebar() {
        NSApp.keyWindow?.firstResponder?.tryToPerform(#selector(NSSplitViewController.toggleSidebar(_:)), with: nil)
    }
    
    public static func selectDirectory(title: String, completion: @escaping (_ path: URL?) -> Void) {
        let dialog = NSOpenPanel();
        dialog.title = title;
        dialog.showsHiddenFiles = false;
        dialog.canChooseFiles = false;
        dialog.canChooseDirectories = true;
        if (dialog.runModal() == NSApplication.ModalResponse.OK) {
            completion(dialog.url)
        } else {
            completion(nil)
        }
    }
    
    public static func selectFile(title: String, completion: @escaping (_ path: URL?) -> Void) {
        let dialog = NSOpenPanel();
        dialog.title = title;
        dialog.showsHiddenFiles = false;
        dialog.canChooseFiles = true;
        dialog.canChooseDirectories = false;
        if (dialog.runModal() == NSApplication.ModalResponse.OK) {
            completion(dialog.url)
        } else {
            completion(nil)
        }
    }
    
    public static func alertInfo(title: String, message: String) {
        guard let window = NSApp.keyWindow else {
            return
        }
        let a = NSAlert()
        a.messageText = title
        a.informativeText = message
        a.addButton(withTitle: "OK")
        a.alertStyle = .informational
        a.beginSheetModal(for: window)
    }
    
    
    public static func alertWarn(title: String, message: String) {
        guard let window = NSApp.keyWindow else {
            return
        }
        let a = NSAlert()
        a.messageText = title
        a.informativeText = message
        a.addButton(withTitle: "OK")
        a.alertStyle = .warning
        a.beginSheetModal(for: window)
    }
    
    public static func isSystemThemeDark() -> Bool {
        return NSApp.effectiveAppearance.name == NSAppearance.Name.darkAqua
    }
    
    public static func inputBox(title: String, message: String, placeholder: String, completionHandler: @escaping (_ inputText: String) -> Void) {
        guard let window = NSApp.keyWindow else {
            return
        }
        let a = NSAlert()
        a.messageText = title
        if !message.isEmpty {
            a.informativeText = message
        }
        a.addButton(withTitle: "OK")
        a.addButton(withTitle: "Cancel")

        let inputTextField = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        inputTextField.placeholderString = placeholder
        a.accessoryView = inputTextField

        a.beginSheetModal(for: window) { resp in
            if resp == .alertFirstButtonReturn {
                let inputText = inputTextField.stringValue
                if inputText.trimmingCharacters(in: .whitespacesAndNewlines) != "" {
                    completionHandler(inputText)
                }
            }
        }
    }
    
    
    public static func alertWarn(title: String, message: String, completionHandler: @escaping (_ isOK: Bool) -> Void) {
        guard let window = NSApp.keyWindow else {
            return
        }
        let a = NSAlert()
        a.messageText = title
        if !message.isEmpty {
            a.informativeText = message
        }
        a.addButton(withTitle: "OK")
        a.addButton(withTitle: "Cancel")
        a.alertStyle = .warning
        a.beginSheetModal(for: window) { resp in
            if resp == .alertFirstButtonReturn {
                completionHandler(true)
            } else {
                completionHandler(false)
            }
        }
    }
    
    public static func saveImage(_ image: NSImage, atUrl url: URL) {
        guard
            let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
            else { return } 
        let newRep = NSBitmapImageRep(cgImage: cgImage)
        newRep.size = image.size // if you want the same size
        guard
            let pngData = newRep.representation(using: .png, properties: [:])
            else { return } // TODO: handle error
        do {
            try pngData.write(to: url)
        }
        catch {
            EZVMLog.error("Failed to save image: \(error.localizedDescription)", logger: EZVMLog.storage)
        }
    }
}

extension View {
    func snapshot() -> NSImage? {
        let controller = NSHostingController(rootView: self)
        let targetSize = controller.view.intrinsicContentSize
        let contentRect = NSRect(origin: .zero, size: targetSize)
        
        let window = NSWindow(
            contentRect: contentRect,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = controller.view
        
        guard
            let bitmapRep = controller.view.bitmapImageRepForCachingDisplay(in: contentRect)
        else { return nil }
        
        controller.view.cacheDisplay(in: contentRect, to: bitmapRep)
        let image = NSImage(size: bitmapRep.size)
        image.addRepresentation(bitmapRep)
        return image
    }
}
