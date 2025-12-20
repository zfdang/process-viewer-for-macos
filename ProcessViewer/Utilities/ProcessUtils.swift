import Foundation
import AppKit
import UniformTypeIdentifiers

/// Utility functions for process-related operations
enum ProcessUtils {
    
    /// Copy process info to clipboard
    static func copyToClipboard(_ process: ProcessInfo) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(process.formattedDescription(), forType: .string)
    }
    
    /// Copy multiple processes info to clipboard
    static func copyToClipboard(_ processes: [ProcessInfo]) {
        let descriptions = processes.map { $0.formattedDescription() }.joined(separator: "\n\n---\n\n")
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(descriptions, forType: .string)
    }
    
    /// Get app icon for a process if available
    static func getAppIcon(for process: ProcessInfo) -> NSImage? {
        let path = process.command
        
        // Try to find .app bundle
        if let range = path.range(of: ".app") {
            let appPath = String(path[..<range.upperBound])
            if let bundle = Bundle(path: appPath),
               let iconName = bundle.object(forInfoDictionaryKey: "CFBundleIconFile") as? String {
                let iconPath: String
                if iconName.hasSuffix(".icns") {
                    iconPath = bundle.bundlePath + "/Contents/Resources/" + iconName
                } else {
                    iconPath = bundle.bundlePath + "/Contents/Resources/" + iconName + ".icns"
                }
                return NSImage(contentsOfFile: iconPath)
            }
            // Try to get icon from workspace
            return NSWorkspace.shared.icon(forFile: appPath)
        }
        
        // Default executable icon using modern API
        if let utType = UTType("public.unix-executable") {
            return NSWorkspace.shared.icon(for: utType)
        }
        
        return nil
    }
}
