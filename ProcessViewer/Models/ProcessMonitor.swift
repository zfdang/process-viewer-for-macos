import Foundation
import Darwin

// Constants not available in Swift's Darwin module
private let PROC_PIDPATHINFO_MAXSIZE: Int32 = 4096
private let defaultGetpwuidBufferSize = 16_384
private let defaultConnectionRefreshIntervalNs: UInt64 = 15_000_000_000
private let maxConnectionWorkers = 4

// MARK: - CPU Sample Data

private struct ProcessCacheKey: Hashable {
    let startSeconds: Int
    let startMicroseconds: Int
    let uid: uid_t
    let comm: String
}

/// Structure to hold CPU sampling data for calculating usage percentage
private struct CPUSample {
    let cacheKey: ProcessCacheKey
    let totalCPUTime: UInt64  // pti_total_user + pti_total_system (Mach absolute time)
    let timestamp: UInt64     // Mach absolute time
}

private struct ProcessMetadataCacheEntry {
    let cacheKey: ProcessCacheKey
    let name: String
    let user: String
    let command: String
}

private struct ConnectionCountCacheEntry {
    let cacheKey: ProcessCacheKey
    let count: Int
    let refreshedAt: UInt64
}

// MARK: - Process Fetching (nonisolated)

/// Helper enum with static methods for fetching processes (not MainActor isolated)
private enum ProcessFetcher {

    /// Get the number of CPU cores
    static var cpuCoreCount: Int = {
        var count: Int32 = 0
        var size = MemoryLayout<Int32>.size
        sysctlbyname("hw.logicalcpu", &count, &size, nil, 0)
        return Int(max(count, 1))
    }()

    /// Fetch all processes using sysctl with CPU usage calculation
    static func fetchAllProcesses(
        previousSamples: [pid_t: CPUSample],
        metadataCache: [pid_t: ProcessMetadataCacheEntry],
        userCache: [uid_t: String],
        connectionCache: [pid_t: ConnectionCountCacheEntry],
        refreshConnections: Bool,
        connectionRefreshIntervalNs: UInt64 = defaultConnectionRefreshIntervalNs
    ) async -> (
        processes: [ProcessInfo],
        hierarchy: [ProcessInfo],
        samples: [pid_t: CPUSample],
        metadataCache: [pid_t: ProcessMetadataCacheEntry],
        userCache: [uid_t: String],
        connectionCache: [pid_t: ConnectionCountCacheEntry]
    ) {
        var result: [ProcessInfo] = []
        var newSamples: [pid_t: CPUSample] = [:]
        var updatedMetadataCache = metadataCache
        var updatedUserCache = userCache
        var currentKeys: [pid_t: ProcessCacheKey] = [:]

        // Use mach_absolute_time for consistent timing with pti_total_user/system.
        let currentTime = mach_absolute_time()
        let nowNs = DispatchTime.now().uptimeNanoseconds
        let cpuCores = Double(cpuCoreCount)

        // Get process list using sysctl
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size: Int = 0

        // First call to get buffer size
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0 else {
            return (result, [], newSamples, [:], updatedUserCache, [:])
        }

        // Allocate buffer
        let count = size / MemoryLayout<kinfo_proc>.stride
        var procList = [kinfo_proc](repeating: kinfo_proc(), count: count)

        // Second call to get actual data
        guard sysctl(&mib, UInt32(mib.count), &procList, &size, nil, 0) == 0 else {
            return (result, [], newSamples, [:], updatedUserCache, [:])
        }

        let actualCount = size / MemoryLayout<kinfo_proc>.stride

        for i in 0..<actualCount {
            let proc = procList[i]
            let pid = proc.kp_proc.p_pid

            // Skip kernel process (pid 0)
            if pid == 0 { continue }

            let fallbackName = withUnsafePointer(to: proc.kp_proc.p_comm) { ptr -> String in
                ptr.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN)) { cstr in
                    String(cString: cstr)
                }
            }
            let cacheKey = processCacheKey(for: proc, fallbackName: fallbackName)
            currentKeys[pid] = cacheKey

            let metadata = resolveMetadata(
                pid: pid,
                fallbackName: fallbackName,
                cacheKey: cacheKey,
                metadataCache: &updatedMetadataCache,
                userCache: &updatedUserCache
            )

            // Get task info for CPU and memory
            var taskInfo = proc_taskinfo()
            let taskInfoSize = MemoryLayout<proc_taskinfo>.size
            let ret = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &taskInfo, Int32(taskInfoSize))
            let hasTaskMetrics = ret == taskInfoSize

            var cpuUsage: Double = 0.0
            var residentMemory: UInt64 = 0
            var virtualMemory: UInt64 = 0
            var threadCount: Int32 = 0
            var priority = Int32(proc.kp_proc.p_priority)

            if hasTaskMetrics {
                let totalCPUTime = taskInfo.pti_total_user + taskInfo.pti_total_system
                newSamples[pid] = CPUSample(cacheKey: cacheKey, totalCPUTime: totalCPUTime, timestamp: currentTime)

                if let prevSample = previousSamples[pid],
                   prevSample.cacheKey == cacheKey,
                   totalCPUTime >= prevSample.totalCPUTime,
                   currentTime > prevSample.timestamp {
                    let cpuTimeDelta = totalCPUTime - prevSample.totalCPUTime
                    let realTimeDelta = currentTime - prevSample.timestamp

                    // Both deltas advance in Mach absolute time units, so their ratio is CPU%.
                    cpuUsage = (Double(cpuTimeDelta) / Double(realTimeDelta)) * 100.0
                    cpuUsage = max(0, min(cpuUsage, cpuCores * 100.0))
                }

                residentMemory = taskInfo.pti_resident_size
                virtualMemory = taskInfo.pti_virtual_size
                threadCount = Int32(taskInfo.pti_threadnum)
                // Apple's `ps` derives PRI from current Mach scheduling data, which requires
                // task/thread inspection APIs we cannot rely on for arbitrary processes here.
                // `pti_priority` is the closest public approximation available alongside the
                // rest of the task metrics we already fetch.
                priority = taskInfo.pti_priority
            }

            result.append(
                ProcessInfo(
                    id: pid,
                    name: metadata.name,
                    ppid: proc.kp_eproc.e_ppid,
                    user: metadata.user,
                    cpuUsage: cpuUsage,
                    residentMemory: residentMemory,
                    virtualMemory: virtualMemory,
                    threadCount: threadCount,
                    priority: priority,
                    nice: Int32(proc.kp_proc.p_nice),
                    command: metadata.command,
                    connectionCount: 0,
                    hasTaskMetrics: hasTaskMetrics,
                    children: []
                )
            )
        }

        let livePIDs = Set(result.map(\.id))
        updatedMetadataCache = updatedMetadataCache.filter { livePIDs.contains($0.key) }

        var counts: [pid_t: Int] = [:]
        var updatedConnectionCache = connectionCache.filter { livePIDs.contains($0.key) }
        var staleConnectionPIDs: [pid_t] = []
        staleConnectionPIDs.reserveCapacity(result.count)

        for proc in result {
            guard let cacheKey = currentKeys[proc.id] else { continue }

            if !refreshConnections,
               let cachedCount = updatedConnectionCache[proc.id],
               cachedCount.cacheKey == cacheKey,
               nowNs >= cachedCount.refreshedAt,
               nowNs - cachedCount.refreshedAt < connectionRefreshIntervalNs {
                counts[proc.id] = cachedCount.count
            } else {
                staleConnectionPIDs.append(proc.id)
            }
        }

        let fetchedCounts = await fetchConnectionCounts(for: staleConnectionPIDs)
        for (pid, count) in fetchedCounts {
            guard let cacheKey = currentKeys[pid] else { continue }
            counts[pid] = count
            updatedConnectionCache[pid] = ConnectionCountCacheEntry(cacheKey: cacheKey, count: count, refreshedAt: nowNs)
        }

        let finalResult = result.map { proc in
            var updated = proc
            updated.connectionCount = counts[proc.id] ?? 0
            return updated
        }.sorted { $0.id < $1.id }

        let hierarchy = buildHierarchy(from: finalResult)
        return (finalResult, hierarchy, newSamples, updatedMetadataCache, updatedUserCache, updatedConnectionCache)
    }

    /// Build parent-child hierarchy from flat process list
    static func buildHierarchy(from processes: [ProcessInfo]) -> [ProcessInfo] {
        var processDict: [pid_t: ProcessInfo] = [:]

        for proc in processes {
            processDict[proc.id] = proc
        }

        var childrenMap: [pid_t: [ProcessInfo]] = [:]
        for proc in processes {
            childrenMap[proc.ppid, default: []].append(proc)
        }

        func buildTree(pid: pid_t) -> ProcessInfo? {
            guard var node = processDict[pid] else { return nil }

            if let children = childrenMap[pid] {
                node.children = children.compactMap { child in
                    buildTree(pid: child.id)
                }.sorted { $0.id < $1.id }
            }

            return node
        }

        var roots: [ProcessInfo] = []
        for proc in processes {
            let isRoot = proc.ppid == 0 ||
                proc.ppid == 1 ||
                processDict[proc.ppid] == nil

            if isRoot && proc.id != 1 {
                if proc.ppid == 1 && processDict[1] != nil {
                    continue
                }
                if let tree = buildTree(pid: proc.id) {
                    roots.append(tree)
                }
            }
        }

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

    private static func fetchConnectionCounts(for pids: [pid_t]) async -> [pid_t: Int] {
        guard !pids.isEmpty else { return [:] }

        let workerCount = max(1, min(min(cpuCoreCount, maxConnectionWorkers), pids.count))
        let chunkSize = max(1, (pids.count + workerCount - 1) / workerCount)

        return await withTaskGroup(of: [pid_t: Int].self) { group in
            for start in stride(from: 0, to: pids.count, by: chunkSize) {
                let end = min(start + chunkSize, pids.count)
                let chunk = Array(pids[start..<end])

                group.addTask {
                    var partial: [pid_t: Int] = [:]
                    partial.reserveCapacity(chunk.count)

                    for pid in chunk {
                        partial[pid] = NetworkConnectionFetcher.connectionCount(for: pid)
                    }

                    return partial
                }
            }

            var counts: [pid_t: Int] = [:]
            counts.reserveCapacity(pids.count)

            for await partial in group {
                counts.merge(partial) { _, new in new }
            }

            return counts
        }
    }

    private static func processCacheKey(for proc: kinfo_proc, fallbackName: String) -> ProcessCacheKey {
        let startTime = proc.kp_proc.p_un.__p_starttime
        return ProcessCacheKey(
            startSeconds: Int(startTime.tv_sec),
            startMicroseconds: Int(startTime.tv_usec),
            uid: proc.kp_eproc.e_ucred.cr_uid,
            comm: fallbackName
        )
    }

    private static func resolveMetadata(
        pid: pid_t,
        fallbackName: String,
        cacheKey: ProcessCacheKey,
        metadataCache: inout [pid_t: ProcessMetadataCacheEntry],
        userCache: inout [uid_t: String]
    ) -> ProcessMetadataCacheEntry {
        if let cached = metadataCache[pid], cached.cacheKey == cacheKey {
            return cached
        }

        var pathBuffer = [CChar](repeating: 0, count: Int(PROC_PIDPATHINFO_MAXSIZE))
        let pathLength = proc_pidpath(pid, &pathBuffer, UInt32(PROC_PIDPATHINFO_MAXSIZE))
        let command = pathLength > 0 ? String(cString: pathBuffer) : fallbackName
        let name = displayName(command: command, fallbackName: fallbackName)
        let user = username(for: cacheKey.uid, cache: &userCache)

        let metadata = ProcessMetadataCacheEntry(cacheKey: cacheKey, name: name, user: user, command: command)
        metadataCache[pid] = metadata
        return metadata
    }

    private static func displayName(command: String, fallbackName: String) -> String {
        guard command != fallbackName else { return fallbackName }
        return command.split(separator: "/").last.map(String.init) ?? fallbackName
    }

    private static func username(for uid: uid_t, cache: inout [uid_t: String]) -> String {
        if let cached = cache[uid] {
            return cached
        }

        let configuredBufferSize = Int(sysconf(Int32(_SC_GETPW_R_SIZE_MAX)))
        let bufferSize = configuredBufferSize > 0 ? configuredBufferSize : defaultGetpwuidBufferSize

        var pwd = passwd()
        var result: UnsafeMutablePointer<passwd>?
        var buffer = [CChar](repeating: 0, count: bufferSize)

        let username: String
        if getpwuid_r(uid, &pwd, &buffer, buffer.count, &result) == 0, result != nil {
            username = String(cString: pwd.pw_name)
        } else {
            username = "unknown"
        }

        cache[uid] = username
        return username
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
    private var metadataCache: [pid_t: ProcessMetadataCacheEntry] = [:]
    private var userCache: [uid_t: String] = [:]
    private var connectionCache: [pid_t: ConnectionCountCacheEntry] = [:]
    private var isRefreshInFlight = false
    private var needsAnotherRefresh = false
    private var pendingConnectionRefresh = false

    init() {
        currentUID = getuid()
        let uidBufferSize = Int(sysconf(Int32(_SC_GETPW_R_SIZE_MAX)))
        let resolvedBufferSize = uidBufferSize > 0 ? uidBufferSize : defaultGetpwuidBufferSize
        var pwd = passwd()
        var result: UnsafeMutablePointer<passwd>?
        var buffer = [CChar](repeating: 0, count: resolvedBufferSize)

        if getpwuid_r(currentUID, &pwd, &buffer, buffer.count, &result) == 0, result != nil {
            currentUser = String(cString: pwd.pw_name)
        } else {
            currentUser = "unknown"
        }

        userCache[currentUID] = currentUser

        Task {
            await refresh(forceRefreshConnections: true, priority: .userInitiated)
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
                await self?.refresh(priority: .utility)
            }
        }
        timer?.tolerance = min(refreshInterval * 0.2, 1.0)
    }

    /// Stop automatic refresh
    func stopAutoRefresh() {
        timer?.invalidate()
        timer = nil
    }

    /// Manually refresh the process list
    func refresh(forceRefreshConnections: Bool = false, priority: TaskPriority = .utility) async {
        if isRefreshInFlight {
            needsAnotherRefresh = true
            pendingConnectionRefresh = pendingConnectionRefresh || forceRefreshConnections
            return
        }

        isRefreshInFlight = true
        isLoading = true

        let previousSamples = cpuSamples
        let previousMetadataCache = metadataCache
        let previousUserCache = userCache
        let previousConnectionCache = connectionCache

        let snapshot = await Task.detached(priority: priority) {
            await ProcessFetcher.fetchAllProcesses(
                previousSamples: previousSamples,
                metadataCache: previousMetadataCache,
                userCache: previousUserCache,
                connectionCache: previousConnectionCache,
                refreshConnections: forceRefreshConnections
            )
        }.value

        cpuSamples = snapshot.samples
        metadataCache = snapshot.metadataCache
        userCache = snapshot.userCache
        connectionCache = snapshot.connectionCache
        flatProcesses = snapshot.processes
        processes = snapshot.hierarchy
        refreshCount += 1
        isLoading = false
        isRefreshInFlight = false

        if needsAnotherRefresh {
            let queuedConnectionRefresh = pendingConnectionRefresh
            needsAnotherRefresh = false
            pendingConnectionRefresh = false
            await refresh(forceRefreshConnections: queuedConnectionRefresh, priority: .utility)
        }
    }

    /// Filter processes based on filter type
    func filteredProcesses(filter: ProcessFilter, searchText: String, hierarchical: Bool = true) -> [ProcessInfo] {
        let matches: (ProcessInfo) -> Bool = { process in
            self.matchesFilter(process, filter: filter) && self.matchesSearch(process, searchText: searchText)
        }

        if !hierarchical {
            return flatProcesses
                .lazy
                .filter(matches)
                .map { proc in
                    var flatProc = proc
                    flatProc.children = []
                    return flatProc
                }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }

        return ProcessFetcher.filterTree(processes, predicate: matches)
    }

    /// Get filtered flat process count
    func filteredCount(filter: ProcessFilter, searchText: String) -> Int {
        flatProcesses.lazy.filter {
            self.matchesFilter($0, filter: filter) && self.matchesSearch($0, searchText: searchText)
        }.count
    }

    private func matchesFilter(_ process: ProcessInfo, filter: ProcessFilter) -> Bool {
        switch filter {
        case .all:
            return true
        case .my:
            return process.user == currentUser && process.id != 0
        case .system:
            return process.user != currentUser || process.id == 0
        case .apps:
            return process.command.contains("/Applications/") || process.command.contains(".app/")
        }
    }

    private func matchesSearch(_ process: ProcessInfo, searchText: String) -> Bool {
        guard !searchText.isEmpty else { return true }

        let lowercasedSearch = searchText.lowercased()
        return process.name.lowercased().contains(lowercasedSearch) ||
            process.command.lowercased().contains(lowercasedSearch) ||
            String(process.id).contains(searchText)
    }
}
