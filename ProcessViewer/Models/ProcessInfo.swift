import Foundation

/// Represents a single process with its properties and child processes
struct ProcessInfo: Identifiable, Hashable {
    let id: pid_t              // PID
    let name: String           // Process name
    let ppid: pid_t            // Parent PID
    let user: String           // Owner username
    var cpuUsage: Double       // CPU percentage
    var residentMemory: UInt64 // Resident memory (bytes)
    var virtualMemory: UInt64  // Virtual memory (bytes)
    var threadCount: Int32     // Number of threads
    let priority: Int32        // Process priority
    let nice: Int32            // Nice value
    let command: String        // Full command path
    var children: [ProcessInfo] // Child processes (for tree hierarchy)
    
    // Computed property to check if process has children
    var hasChildren: Bool {
        !children.isEmpty
    }
    
    // Hash based on PID only for Hashable conformance
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
    
    static func == (lhs: ProcessInfo, rhs: ProcessInfo) -> Bool {
        lhs.id == rhs.id
    }
    
    /// Format memory size to human-readable string
    static func formatMemory(_ bytes: UInt64) -> String {
        let kb = Double(bytes) / 1024.0
        let mb = kb / 1024.0
        let gb = mb / 1024.0
        
        if gb >= 1.0 {
            return String(format: "%.2f GB", gb)
        } else if mb >= 1.0 {
            return String(format: "%.1f MB", mb)
        } else if kb >= 1.0 {
            return String(format: "%.0f KB", kb)
        } else {
            return "\(bytes) B"
        }
    }
    
    /// Generate formatted string for clipboard copy
    func formattedDescription() -> String {
        """
        \(L.s("desc.pid")): \(id)
        \(L.s("desc.name")): \(name)
        \(L.s("desc.user")): \(user)
        \(L.s("desc.cpu")): \(String(format: "%.1f%%", cpuUsage))
        \(L.s("desc.resMem")): \(ProcessInfo.formatMemory(residentMemory))
        \(L.s("desc.virMem")): \(ProcessInfo.formatMemory(virtualMemory))
        \(L.s("desc.threads")): \(threadCount)
        \(L.s("desc.prio")): \(priority)/\(nice)
        \(L.s("desc.command")): \(command)
        """
    }
}

/// Filter type for process listing
enum ProcessFilter: String, CaseIterable, Identifiable {
    case apps = "Apps"
    case my = "My"
    case system = "System"
    case all = "All"
    
    var id: String { rawValue }
    
    var localizedName: String {
        switch self {
        case .apps: return L.s("filter.apps")
        case .my: return L.s("filter.my")
        case .system: return L.s("filter.system")
        case .all: return L.s("filter.all")
        }
    }
}
