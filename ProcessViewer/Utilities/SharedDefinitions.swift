import Foundation
import SwiftUI

/// Row size for the outline view
enum RowSize: String, CaseIterable {
    case small = "S"
    case medium = "M"
    case large = "L"
}

extension Notification.Name {
    /// Notification posted when process info is copied to clipboard
    static let processCopied = Notification.Name("processCopied")
}
