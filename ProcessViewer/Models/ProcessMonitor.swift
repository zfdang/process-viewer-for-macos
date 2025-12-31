import Foundation
import Darwin

// Constants not available in Swift's Darwin module
private let PROC_PIDPATHINFO_MAXSIZE: Int32 = 4096

// MARK: - CPU Sample Data

/// Structure to hold CPU sampling data for calculating usage percentage
struct CPUSample {
    let totalCPUTime: UInt64  // pti_total_user + pti_total_system (Mach absolute time)
    let timestamp: UInt64     // Mach absolute time
}

// MARK: - Process Fetching (nonisolated)

/// Helper enum with static methods for fetching processes (not MainActor isolated)
enum ProcessFetcher {
    
    /// Get the number of CPU cores
    static var cpuCoreCount: Int = {
        var count: Int32 = 0
        var size = MemoryLayout<Int32>.size
        sysctlbyname("hw.logicalcpu", &count, &size, nil, 0)
        return Int(max(count, 1))
    }()
    
    /// Fetch all processes using sysctl with CPU usage calculation
    static func fetchAllProcesses(previousSamples: [pid_t: CPUSample]) async -> (processes: [ProcessInfo], samples: [pid_t: CPUSample]) {
        var result: [ProcessInfo] = []
        var newSamples: [pid_t: CPUSample] = [:]
        
        // Use mach_absolute_time for consistent timing with pti_total_user/system
        let currentTime = mach_absolute_time()
        let cpuCores = Double(cpuCoreCount)
        
        // Get process list using sysctl
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size: Int = 0
        
        // First call to get buffer size
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0 else {
            return (result, newSamples)
        }
        
        // Allocate buffer
        let count = size / MemoryLayout<kinfo_proc>.stride
        var procList = [kinfo_proc](repeating: kinfo_proc(), count: count)
        
        // Second call to get actual data
        guard sysctl(&mib, UInt32(mib.count), &procList, &size, nil, 0) == 0 else {
            return (result, newSamples)
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
                // pti_total_user and pti_total_system - total CPU time used
                let totalCPUTime = taskInfo.pti_total_user + taskInfo.pti_total_system
                
                // Store current sample for next calculation
                newSamples[pid] = CPUSample(totalCPUTime: totalCPUTime, timestamp: currentTime)
                
                // Calculate CPU usage percentage if we have previous sample
                if let prevSample = previousSamples[pid] {
                    // Make sure CPU time increased (protect against PID reuse)
                    if totalCPUTime >= prevSample.totalCPUTime && currentTime > prevSample.timestamp {
                        let cpuTimeDelta = totalCPUTime - prevSample.totalCPUTime
                        let realTimeDelta = currentTime - prevSample.timestamp
                        
                        // CPU% = (CPU time delta / real time delta) * 100
                        // Both are in the same unit (Mach absolute time), so ratio is correct
                        cpuUsage = (Double(cpuTimeDelta) / Double(realTimeDelta)) * 100.0
                        
                        // Clamp to reasonable range (0 to cores * 100)
                        cpuUsage = max(0, min(cpuUsage, cpuCores * 100.0))
                    }
                }
                // If no previous sample, cpuUsage remains 0 (first measurement)
                
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
                connectionCount: 0, // Will be filled in parallel
                children: []
            )
            
            result.append(processInfo)
        }
        
        // Fetch connection counts in parallel to reduce background task duration
        let finalResult = await withTaskGroup(of: (pid_t, Int).self) { group -> [ProcessInfo] in
            for proc in result {
                group.addTask {
                    return (proc.id, NetworkConnectionFetcher.connectionCount(for: proc.id))
                }
            }
            
            var counts: [pid_t: Int] = [:]
            for await (pid, count) in group {
                counts[pid] = count
            }
            
            return result.map { proc in
                var updated = proc
                updated.connectionCount = counts[proc.id] ?? 0
                return updated
            }
        }
        
        return (finalResult.sorted { $0.id < $1.id }, newSamples)
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
    
}

// MARK: - Process Monitor (MainActor)

/// Observable class that fetches and monitors system processes
@MainActor
class ProcessMonitor: ObservableObject {
    @Published var processes: [ProcessInfo] = []
    @Published var flatProcesses: [ProcessInfo] = []
    @Published var isLoading = false
    @Published var refreshCount: Int = 0
    
    private var timer: Timer?
    private var refreshInterval: TimeInterval = 3.0
    private let currentUID: uid_t
    private let currentUser: String
    
    /// Store previous CPU samples for calculating usage percentage
    private var cpuSamples: [pid_t: CPUSample] = [:]
    
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
        
        // Capture current samples for background task
        let previousSamples = self.cpuSamples
        
        // Fetch processes in background using nonisolated ProcessFetcher
        let (fetchedProcesses, newSamples) = await Task.detached(priority: .userInitiated) {
            return await ProcessFetcher.fetchAllProcesses(previousSamples: previousSamples)
        }.value
        
        // Update samples for next refresh
        self.cpuSamples = newSamples
        
        // Build hierarchy (can be done on main thread as it's just data manipulation)
        let hierarchy = ProcessFetcher.buildHierarchy(from: fetchedProcesses)
        
        self.flatProcesses = fetchedProcesses
        self.processes = hierarchy
        self.refreshCount += 1
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
                result = result.filter { $0.user != currentUser }
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
            result = ProcessFetcher.filterTree(result) { $0.user != currentUser }
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
    /// Get filtered flat process count
    func filteredCount(filter: ProcessFilter, searchText: String) -> Int {
        // Always use flat results for counting to ensure accuracy (My + System = All)
        return filteredProcesses(filter: filter, searchText: searchText, hierarchical: false).count
    }
}
