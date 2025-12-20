import Foundation
import Darwin

// Constants not available in Swift's Darwin module
private let PROC_PIDPATHINFO_MAXSIZE: Int32 = 4096

// MARK: - Process Fetching (nonisolated)

/// Helper enum with static methods for fetching processes (not MainActor isolated)
enum ProcessFetcher {
    
    /// Fetch all processes using sysctl
    static func fetchAllProcesses() -> [ProcessInfo] {
        var result: [ProcessInfo] = []
        
        // Get process list using sysctl
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size: Int = 0
        
        // First call to get buffer size
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0 else {
            return result
        }
        
        // Allocate buffer
        let count = size / MemoryLayout<kinfo_proc>.stride
        var procList = [kinfo_proc](repeating: kinfo_proc(), count: count)
        
        // Second call to get actual data
        guard sysctl(&mib, UInt32(mib.count), &procList, &size, nil, 0) == 0 else {
            return result
        }
        
        let actualCount = size / MemoryLayout<kinfo_proc>.stride
        
        for i in 0..<actualCount {
            let proc = procList[i]
            let pid = proc.kp_proc.p_pid
            
            // Skip kernel process (pid 0)
            if pid == 0 { continue }
            
            // Get process name
            var name = withUnsafePointer(to: proc.kp_proc.p_comm) { ptr -> String in
                return ptr.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN)) { cstr in
                    return String(cString: cstr)
                }
            }
            
            // Get full path using proc_pidpath
            var pathBuffer = [CChar](repeating: 0, count: Int(PROC_PIDPATHINFO_MAXSIZE))
            let pathLength = proc_pidpath(pid, &pathBuffer, UInt32(PROC_PIDPATHINFO_MAXSIZE))
            let command = pathLength > 0 ? String(cString: pathBuffer) : name
            
            // If we got full path, use the executable name as display name
            if pathLength > 0 {
                if let lastComponent = command.split(separator: "/").last {
                    name = String(lastComponent)
                }
            }
            
            // Get username
            let uid = proc.kp_eproc.e_ucred.cr_uid
            var username = "unknown"
            if let pw = getpwuid(uid) {
                username = String(cString: pw.pointee.pw_name)
            }
            
            // Get task info for CPU and memory
            var taskInfo = proc_taskinfo()
            let taskInfoSize = MemoryLayout<proc_taskinfo>.size
            let ret = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &taskInfo, Int32(taskInfoSize))
            
            var cpuUsage: Double = 0.0
            var residentMemory: UInt64 = 0
            var virtualMemory: UInt64 = 0
            var threadCount: Int32 = 0
            
            if ret == taskInfoSize {
                // CPU usage calculation (simplified - shows instantaneous usage)
                let totalTime = Double(taskInfo.pti_total_user + taskInfo.pti_total_system)
                cpuUsage = totalTime / 1_000_000_000.0 // Nanoseconds to seconds
                
                residentMemory = taskInfo.pti_resident_size
                virtualMemory = taskInfo.pti_virtual_size
                threadCount = Int32(taskInfo.pti_threadnum)
            }
            
            let processInfo = ProcessInfo(
                id: pid,
                name: name,
                ppid: proc.kp_eproc.e_ppid,
                user: username,
                cpuUsage: cpuUsage,
                residentMemory: residentMemory,
                virtualMemory: virtualMemory,
                threadCount: threadCount,
                priority: Int32(proc.kp_proc.p_priority),
                nice: Int32(proc.kp_proc.p_nice),
                command: command,
                children: []
            )
            
            result.append(processInfo)
        }
        
        return result.sorted { $0.id < $1.id }
    }
    
    /// Build parent-child hierarchy from flat process list
    static func buildHierarchy(from processes: [ProcessInfo]) -> [ProcessInfo] {
        var processDict: [pid_t: ProcessInfo] = [:]
        
        // First pass: create dictionary
        for proc in processes {
            processDict[proc.id] = proc
        }
        
        // Second pass: build children
        var childrenMap: [pid_t: [ProcessInfo]] = [:]
        for proc in processes {
            childrenMap[proc.ppid, default: []].append(proc)
        }
        
        // Third pass: assign children and find roots
        func buildTree(pid: pid_t) -> ProcessInfo? {
            guard var node = processDict[pid] else { return nil }
            
            if let children = childrenMap[pid] {
                node.children = children.compactMap { child in
                    buildTree(pid: child.id)
                }.sorted { $0.id < $1.id }
            }
            
            return node
        }
        
        // Find root processes (ppid not in our list or ppid is 0 or 1)
        var roots: [ProcessInfo] = []
        for proc in processes {
            // Root if parent doesn't exist in our list, or parent is 0, or parent is 1 (launchd)
            let isRoot = proc.ppid == 0 || 
                        proc.ppid == 1 || 
                        processDict[proc.ppid] == nil
            
            if isRoot && proc.id != 1 {
                // Skip if this is a child of launchd (will be added as child of launchd)
                if proc.ppid == 1 && processDict[1] != nil {
                    continue
                }
                if let tree = buildTree(pid: proc.id) {
                    roots.append(tree)
                }
            }
        }
        
        // Add launchd (pid 1) as root if it exists
        if let launchd = buildTree(pid: 1) {
            roots.insert(launchd, at: 0)
        }
        
        return roots.sorted { $0.id < $1.id }
    }
    
    /// Filter tree while preserving hierarchy
    static func filterTree(_ processes: [ProcessInfo], predicate: (ProcessInfo) -> Bool) -> [ProcessInfo] {
        func filterNode(_ node: ProcessInfo) -> ProcessInfo? {
            let filteredChildren = node.children.compactMap { filterNode($0) }
            
            if predicate(node) || !filteredChildren.isEmpty {
                var result = node
                result.children = filteredChildren
                return result
            }
            
            return nil
        }
        
        return processes.compactMap { filterNode($0) }
    }
    
    /// Count all processes in hierarchy
    static func countAllProcesses(in processes: [ProcessInfo]) -> Int {
        var count = 0
        for proc in processes {
            count += 1
            count += countAllProcesses(in: proc.children)
        }
        return count
    }
}

// MARK: - Process Monitor (MainActor)

/// Observable class that fetches and monitors system processes
@MainActor
class ProcessMonitor: ObservableObject {
    @Published var processes: [ProcessInfo] = []
    @Published var flatProcesses: [ProcessInfo] = []
    @Published var isLoading = false
    @Published var processCount = 0
    
    private var timer: Timer?
    private var refreshInterval: TimeInterval = 3.0
    private let currentUID: uid_t
    private let currentUser: String
    
    init() {
        // Get current UID and username (these are safe to call)
        currentUID = getuid()
        if let pw = getpwuid(currentUID) {
            currentUser = String(cString: pw.pointee.pw_name)
        } else {
            currentUser = "unknown"
        }
        
        // Initial fetch
        Task {
            await refresh()
        }
    }
    
    deinit {
        timer?.invalidate()
        timer = nil
    }
    
    /// Start automatic refresh with specified interval
    func startAutoRefresh(interval: TimeInterval = 3.0) {
        refreshInterval = interval
        stopAutoRefresh()
        
        timer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.refresh()
            }
        }
    }
    
    /// Stop automatic refresh
    func stopAutoRefresh() {
        timer?.invalidate()
        timer = nil
    }
    
    /// Manually refresh the process list
    func refresh() async {
        isLoading = true
        
        // Fetch processes in background using nonisolated ProcessFetcher
        let fetchedProcesses = await Task.detached(priority: .userInitiated) {
            return ProcessFetcher.fetchAllProcesses()
        }.value
        
        // Build hierarchy (can be done on main thread as it's just data manipulation)
        let hierarchy = ProcessFetcher.buildHierarchy(from: fetchedProcesses)
        
        self.flatProcesses = fetchedProcesses
        self.processes = hierarchy
        self.processCount = fetchedProcesses.count
        self.isLoading = false
    }
    
    /// Filter processes based on filter type
    func filteredProcesses(filter: ProcessFilter, searchText: String, hierarchical: Bool = true) -> [ProcessInfo] {
        // For flat view, use flatProcesses as source
        if !hierarchical {
            var result = flatProcesses
            
            // Apply filter
            switch filter {
            case .all:
                break
            case .my:
                result = result.filter { $0.user == currentUser }
            case .system:
                result = result.filter { $0.user == "root" || $0.user == "_windowserver" || $0.user.hasPrefix("_") }
            case .apps:
                result = result.filter { $0.command.contains("/Applications/") || $0.command.contains(".app/") }
            }
            
            // Apply search
            if !searchText.isEmpty {
                let lowercasedSearch = searchText.lowercased()
                result = result.filter {
                    $0.name.lowercased().contains(lowercasedSearch) ||
                    $0.command.lowercased().contains(lowercasedSearch) ||
                    String($0.id).contains(searchText)
                }
            }
            
            // Return as flat list (processes with empty children)
            return result.map { proc in
                var flatProc = proc
                flatProc.children = []
                return flatProc
            }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
        
        // Hierarchical view
        var result = processes
        
        // Apply filter
        switch filter {
        case .all:
            break
        case .my:
            result = ProcessFetcher.filterTree(result) { $0.user == currentUser }
        case .system:
            result = ProcessFetcher.filterTree(result) { $0.user == "root" || $0.user == "_windowserver" || $0.user.hasPrefix("_") }
        case .apps:
            result = ProcessFetcher.filterTree(result) { $0.command.contains("/Applications/") || $0.command.contains(".app/") }
        }
        
        // Apply search
        if !searchText.isEmpty {
            let lowercasedSearch = searchText.lowercased()
            result = ProcessFetcher.filterTree(result) {
                $0.name.lowercased().contains(lowercasedSearch) ||
                $0.command.lowercased().contains(lowercasedSearch) ||
                String($0.id).contains(searchText)
            }
        }
        
        return result
    }
    
    /// Get filtered flat process count
    func filteredCount(filter: ProcessFilter, searchText: String) -> Int {
        let filtered = filteredProcesses(filter: filter, searchText: searchText)
        return ProcessFetcher.countAllProcesses(in: filtered)
    }
}
