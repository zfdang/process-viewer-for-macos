import Foundation

/// Represents a single process with its properties and child processes
struct ProcessInfo: Identifiable, Hashable, Sendable {
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
    var connectionCount: Int?  // Number of network connections; nil when the kernel refuses access
    let hasTaskMetrics: Bool   // Whether task-based metrics are available for this process
    let isApp: Bool            // Whether the executable lives inside an .app bundle / Applications
    var children: [ProcessInfo] // Child processes (for tree hierarchy)

    // Precomputed lowercase forms used by the search predicate. Computing these
    // once per fetch avoids re-allocating lowercased copies on every keystroke
    // (the search predicate runs over every process for each character typed).
    let lowercaseName: String
    let lowercaseCommand: String

    init(
        id: pid_t,
        name: String,
        ppid: pid_t,
        user: String,
        cpuUsage: Double,
        residentMemory: UInt64,
        virtualMemory: UInt64,
        threadCount: Int32,
        priority: Int32,
        nice: Int32,
        command: String,
        connectionCount: Int?,
        hasTaskMetrics: Bool,
        isApp: Bool,
        children: [ProcessInfo]
    ) {
        self.id = id
        self.name = name
        self.ppid = ppid
        self.user = user
        self.cpuUsage = cpuUsage
        self.residentMemory = residentMemory
        self.virtualMemory = virtualMemory
        self.threadCount = threadCount
        self.priority = priority
        self.nice = nice
        self.command = command
        self.connectionCount = connectionCount
        self.hasTaskMetrics = hasTaskMetrics
        self.isApp = isApp
        self.children = children
        self.lowercaseName = name.lowercased()
        self.lowercaseCommand = command.lowercased()
    }

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

    var formattedCPUUsage: String {
        hasTaskMetrics ? String(format: "%.1f", cpuUsage) : "--"
    }

    var formattedResidentMemory: String {
        hasTaskMetrics ? Self.formatMemory(residentMemory) : "--"
    }

    var formattedVirtualMemory: String {
        hasTaskMetrics ? Self.formatMemory(virtualMemory) : "--"
    }

    var formattedThreadCount: String {
        hasTaskMetrics ? "\(threadCount)" : "--"
    }

    var formattedConnectionCount: String {
        connectionCount.map { "\($0)" } ?? "--"
    }

    /// Sort key for the connections column: unknown counts sort below zero so
    /// "no data" never masquerades as "no connections" at the top of the list.
    var connectionSortValue: Int {
        connectionCount ?? -1
    }

    /// Whether `command` points into an application bundle. Computed once per
    /// process (the path never changes for a live PID) so the "Apps" filter is a
    /// boolean check instead of two substring searches per process per redraw.
    static func isAppBundleCommand(_ command: String) -> Bool {
        command.contains("/Applications/") || command.contains(".app/")
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
        \(L.s("desc.cpu")): \(hasTaskMetrics ? "\(formattedCPUUsage)%" : "--")
        \(L.s("desc.resMem")): \(formattedResidentMemory)
        \(L.s("desc.virMem")): \(formattedVirtualMemory)
        \(L.s("desc.threads")): \(formattedThreadCount)
        \(L.s("desc.connections")): \(formattedConnectionCount)
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
