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
    
    /// Get app icon for a process if available
    static func getAppIcon(for commandPath: String) -> NSImage? {
        // Try to find .app bundle in the path
        if let range = commandPath.range(of: ".app") {
            let appPath = String(commandPath[..<range.upperBound])
            return NSWorkspace.shared.icon(forFile: appPath)
        }
        
        // For non-app executables or if .app extraction fails, return nil
        // so the caller can provide a default icon
        return nil
    }
}
