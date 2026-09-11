import Foundation
import Darwin

// Constants not available in Swift's Darwin module
private let PROC_PIDPATHINFO_MAXSIZE: Int32 = 4096
private let defaultGetpwuidBufferSize = 16_384

/// CPU% is the ratio of consumed CPU time to wall time between two samples of the
/// same process. A manual refresh (⌘R) landing a few hundred milliseconds after an
/// automatic tick would otherwise compute the ratio over a window so short that a
/// single scheduler quantum reads as tens of percent. Below this window we keep the
/// older baseline sample and carry the previously displayed value forward, so the
/// figure always reflects at least this much wall time — the same idea as
/// Activity Monitor's fixed update interval.
private let minimumCPUSampleWindowNs: UInt64 = 1_000_000_000

/// Upper bound on the sampling window. Sampling is suspended while the window is
/// hidden, so the first refresh after it reappears could otherwise average CPU
/// time over minutes and present that as "current" usage. Past this bound the
/// stale baseline is discarded, the row shows 0 like a first sample, and the
/// quick follow-up refresh scheduled on unhide produces a fresh short-window value.
private let maximumCPUSampleWindowNs: UInt64 = 30_000_000_000

// MARK: - CPU Sample Data

private struct ProcessCacheKey: Hashable, Sendable {
    let startSeconds: Int
    let startMicroseconds: Int
    let uid: uid_t
    let comm: String
}

/// Structure to hold CPU sampling data for calculating usage percentage
private struct CPUSample: Sendable {
    let cacheKey: ProcessCacheKey
    let totalCPUTime: UInt64  // pti_total_user + pti_total_system (Mach absolute time)
    let timestamp: UInt64     // Mach absolute time, taken alongside the task-info call
    let cpuUsage: Double      // Last displayed CPU%, carried forward across short windows
}

private struct ProcessMetadataCacheEntry: Sendable {
    let cacheKey: ProcessCacheKey
    let name: String
    let user: String
    let command: String
    let isApp: Bool
}

private struct ProcessFetchSnapshot: Sendable {
    let processes: [ProcessInfo]
    let hierarchy: [ProcessInfo]
    let samples: [pid_t: CPUSample]
    let metadataCache: [pid_t: ProcessMetadataCacheEntry]
    let userCache: [uid_t: String]
}

private func resolveUsername(for uid: uid_t, cache: inout [uid_t: String]) -> String {
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

/// Mach absolute time → nanoseconds conversion factor, resolved once.
private let machTimebase: mach_timebase_info_data_t = {
    var info = mach_timebase_info_data_t()
    mach_timebase_info(&info)
    return info
}()

private func machTicksToNanoseconds(_ ticks: UInt64) -> UInt64 {
    ticks * UInt64(machTimebase.numer) / UInt64(machTimebase.denom)
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

    /// Fetch all processes using sysctl with CPU usage calculation.
    ///
    /// Everything — task metrics, metadata and the socket count — is gathered in a
    /// single pass over the process table. Measured on a ~740-process system the
    /// whole pass costs about 5 ms, so nothing here is worth caching across
    /// refreshes except the per-process metadata (path lookups) and usernames.
    static func fetchAllProcesses(
        previousSamples: [pid_t: CPUSample],
        metadataCache: [pid_t: ProcessMetadataCacheEntry],
        userCache: [uid_t: String]
    ) -> ProcessFetchSnapshot {
        var result: [ProcessInfo] = []
        var newSamples: [pid_t: CPUSample] = [:]
        var updatedMetadataCache = metadataCache
        var updatedUserCache = userCache

        let cpuCores = Double(cpuCoreCount)

        // Get process list using sysctl
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size: Int = 0

        // First call to get buffer size
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0 else {
            return ProcessFetchSnapshot(
                processes: result,
                hierarchy: [],
                samples: previousSamples,
                metadataCache: updatedMetadataCache,
                userCache: updatedUserCache
            )
        }

        // Allocate buffer
        let count = size / MemoryLayout<kinfo_proc>.stride
        var procList = [kinfo_proc](repeating: kinfo_proc(), count: count)

        // Second call to get actual data
        guard sysctl(&mib, UInt32(mib.count), &procList, &size, nil, 0) == 0 else {
            return ProcessFetchSnapshot(
                processes: result,
                hierarchy: [],
                samples: previousSamples,
                metadataCache: updatedMetadataCache,
                userCache: updatedUserCache
            )
        }

        let actualCount = size / MemoryLayout<kinfo_proc>.stride
        result.reserveCapacity(actualCount)
        newSamples.reserveCapacity(actualCount)

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

            let metadata = resolveMetadata(
                pid: pid,
                fallbackName: fallbackName,
                cacheKey: cacheKey,
                metadataCache: &updatedMetadataCache,
                userCache: &updatedUserCache
            )

            // Get task info for CPU and memory. The timestamp is taken right next
            // to the syscall so every process gets its own accurate sample time
            // instead of sharing one taken before the loop started.
            var taskInfo = proc_taskinfo()
            let taskInfoSize = MemoryLayout<proc_taskinfo>.size
            let ret = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &taskInfo, Int32(taskInfoSize))
            let sampleTime = mach_absolute_time()
            let hasTaskMetrics = ret == taskInfoSize

            var cpuUsage: Double = 0.0
            var residentMemory: UInt64 = 0
            var virtualMemory: UInt64 = 0
            var threadCount: Int32 = 0
            var priority = Int32(proc.kp_proc.p_priority)

            if hasTaskMetrics {
                let totalCPUTime = taskInfo.pti_total_user + taskInfo.pti_total_system
                var sample = CPUSample(cacheKey: cacheKey, totalCPUTime: totalCPUTime, timestamp: sampleTime, cpuUsage: 0)

                if let prevSample = previousSamples[pid],
                   prevSample.cacheKey == cacheKey,
                   totalCPUTime >= prevSample.totalCPUTime,
                   sampleTime > prevSample.timestamp {
                    let cpuTimeDelta = totalCPUTime - prevSample.totalCPUTime
                    let realTimeDelta = sampleTime - prevSample.timestamp

                    let windowNs = machTicksToNanoseconds(realTimeDelta)
                    if windowNs < minimumCPUSampleWindowNs {
                        // Window too short for a meaningful ratio: keep the old
                        // baseline and redisplay the last good value.
                        cpuUsage = prevSample.cpuUsage
                        sample = prevSample
                    } else if windowNs <= maximumCPUSampleWindowNs {
                        // Both deltas advance in Mach absolute time units, so their ratio is CPU%.
                        cpuUsage = (Double(cpuTimeDelta) / Double(realTimeDelta)) * 100.0
                        cpuUsage = max(0, min(cpuUsage, cpuCores * 100.0))
                        sample = CPUSample(cacheKey: cacheKey, totalCPUTime: totalCPUTime, timestamp: sampleTime, cpuUsage: cpuUsage)
                    }
                    // Otherwise the baseline is too old to describe the present;
                    // `sample` already holds a fresh baseline with cpuUsage 0.
                }
                newSamples[pid] = sample

                residentMemory = taskInfo.pti_resident_size
                virtualMemory = taskInfo.pti_virtual_size
                threadCount = Int32(taskInfo.pti_threadnum)
                // Apple's `ps` derives PRI from current Mach scheduling data, which requires
                // task/thread inspection APIs we cannot rely on for arbitrary processes here.
                // `pti_priority` is the closest public approximation available alongside the
                // rest of the task metrics we already fetch.
                priority = taskInfo.pti_priority
            }

            // Socket count. The kernel only exposes descriptor tables of processes
            // we own (unless running as root); for the rest this yields
            // `.unavailable`, which the UI renders as "--" rather than a false 0.
            let connectionCount: Int?
            switch NetworkConnectionFetcher.connectionCount(for: pid) {
            case .count(let value): connectionCount = value
            case .unavailable: connectionCount = nil
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
                    connectionCount: connectionCount,
                    hasTaskMetrics: hasTaskMetrics,
                    isApp: metadata.isApp,
                    children: []
                )
            )
        }

        // Drop metadata for processes that have exited so the cache tracks the
        // live process table instead of growing for the lifetime of the app.
        if updatedMetadataCache.count != result.count {
            let livePIDs = Set(result.map(\.id))
            updatedMetadataCache = updatedMetadataCache.filter { livePIDs.contains($0.key) }
        }

        result.sort { $0.id < $1.id }

        let hierarchy = buildHierarchy(from: result)
        return ProcessFetchSnapshot(
            processes: result,
            hierarchy: hierarchy,
            samples: newSamples,
            metadataCache: updatedMetadataCache,
            userCache: updatedUserCache
        )
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
        let user = resolveUsername(for: cacheKey.uid, cache: &userCache)

        let metadata = ProcessMetadataCacheEntry(
            cacheKey: cacheKey,
            name: name,
            user: user,
            command: command,
            isApp: ProcessInfo.isAppBundleCommand(command)
        )
        metadataCache[pid] = metadata
        return metadata
    }

    private static func displayName(command: String, fallbackName: String) -> String {
        guard command != fallbackName else { return fallbackName }
        return command.split(separator: "/").last.map(String.init) ?? fallbackName
    }

}

// MARK: - Process Monitor (MainActor)

/// Observable class that fetches and monitors system processes
@MainActor
class ProcessMonitor: ObservableObject {
    @Published var processes: [ProcessInfo] = []
    /// Flat list backing the non-hierarchical filter. Not published: the view
    /// layer only ever reads it through the memoized filter, and publishing it
    /// would invalidate the SwiftUI body once more per refresh for nothing.
    private var flatProcesses: [ProcessInfo] = []
    /// True while the initial load or a user-initiated refresh is running.
    /// Background timer ticks do not touch this: toggling it forced two extra
    /// SwiftUI body evaluations and a spinner animation every five seconds.
    @Published var isLoading = false
    @Published var refreshCount: Int = 0

    private var timer: Timer?
    private var refreshInterval: TimeInterval = 5.0
    private var autoRefreshEnabled = false
    private var isWindowVisible = true
    private let currentUID: uid_t
    private let currentUser: String

    /// Store previous CPU samples for calculating usage percentage
    private var cpuSamples: [pid_t: CPUSample] = [:]
    private var metadataCache: [pid_t: ProcessMetadataCacheEntry] = [:]
    private var userCache: [uid_t: String] = [:]
    private var isRefreshInFlight = false
    private var needsAnotherRefresh = false
    private var pendingUserInitiated = false

    // Memo for the filtered view. SwiftUI may evaluate ContentView's body
    // several times per refresh and reads both the filtered list and the count;
    // recomputing the filter over every process each time was the single
    // largest CPU cost in the app.
    private struct FilterMemoKey: Equatable {
        let refreshCount: Int
        let filter: ProcessFilter
        let searchText: String
        let hierarchical: Bool
    }
    private var filterMemoKey: FilterMemoKey?
    private var filterMemoProcesses: [ProcessInfo] = []
    private var filterMemoCount = 0

    init() {
        currentUID = getuid()
        var initialUserCache: [uid_t: String] = [:]
        currentUser = resolveUsername(for: currentUID, cache: &initialUserCache)
        userCache = initialUserCache

        Task {
            await refresh(userInitiated: true)
        }
    }

    deinit {
        timer?.invalidate()
        timer = nil
    }

    /// Start automatic refresh with specified interval
    func startAutoRefresh(interval: TimeInterval = 5.0) {
        refreshInterval = interval
        autoRefreshEnabled = true
        scheduleTimerIfNeeded()
    }

    /// Stop automatic refresh
    func stopAutoRefresh() {
        autoRefreshEnabled = false
        timer?.invalidate()
        timer = nil
    }

    /// Called by the view layer when the hosting window becomes visible or is
    /// hidden / minimized / fully occluded. Sampling a process table nobody can
    /// see is pure waste, so the timer is suspended while invisible and a fresh
    /// sample is taken the moment the window is shown again.
    func setWindowVisible(_ visible: Bool) {
        guard visible != isWindowVisible else { return }
        isWindowVisible = visible

        if visible {
            scheduleTimerIfNeeded()
            if autoRefreshEnabled {
                // Sample now to re-establish CPU baselines (the old ones are
                // likely past `maximumCPUSampleWindowNs`), then again shortly
                // after so real CPU% appears without waiting a full interval.
                Task {
                    await refresh()
                    try? await Task.sleep(nanoseconds: minimumCPUSampleWindowNs)
                    await refresh()
                }
            }
        } else {
            timer?.invalidate()
            timer = nil
        }
    }

    private func scheduleTimerIfNeeded() {
        timer?.invalidate()
        timer = nil
        guard autoRefreshEnabled, isWindowVisible else { return }

        timer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.refresh()
            }
        }
        // Generous tolerance lets macOS coalesce this timer with other fires,
        // dropping wakeups on battery — a process viewer doesn't need sub-second
        // accuracy on its refresh cadence.
        timer?.tolerance = min(refreshInterval * 0.4, 2.0)
    }

    /// Refresh the process list.
    /// - Parameter userInitiated: true for the initial load and explicit ⌘R;
    ///   drives the loading indicator and a higher task priority.
    func refresh(userInitiated: Bool = false) async {
        if isRefreshInFlight {
            // Coalesce: the running pass will run one more time when it finishes.
            needsAnotherRefresh = true
            pendingUserInitiated = pendingUserInitiated || userInitiated
            return
        }

        isRefreshInFlight = true
        defer { isRefreshInFlight = false }

        var runAsUserInitiated = userInitiated
        repeat {
            if runAsUserInitiated {
                isLoading = true
            }

            let previousSamples = cpuSamples
            let previousMetadataCache = metadataCache
            let previousUserCache = userCache

            let snapshot = await Task.detached(priority: runAsUserInitiated ? .userInitiated : .utility) {
                ProcessFetcher.fetchAllProcesses(
                    previousSamples: previousSamples,
                    metadataCache: previousMetadataCache,
                    userCache: previousUserCache
                )
            }.value

            cpuSamples = snapshot.samples
            metadataCache = snapshot.metadataCache
            userCache = snapshot.userCache
            flatProcesses = snapshot.processes
            processes = snapshot.hierarchy
            refreshCount += 1
            if isLoading {
                isLoading = false
            }

            // Drain any request that arrived mid-pass. Looping (rather than
            // recursing) keeps the async frame depth flat however many
            // coalesced requests come in.
            guard needsAnotherRefresh else { break }
            runAsUserInitiated = pendingUserInitiated
            needsAnotherRefresh = false
            pendingUserInitiated = false
        } while true
    }

    /// Filter processes based on filter type
    func filteredProcesses(filter: ProcessFilter, searchText: String, hierarchical: Bool = true) -> [ProcessInfo] {
        ensureFilterMemo(filter: filter, searchText: searchText, hierarchical: hierarchical)
        return filterMemoProcesses
    }

    /// Get filtered flat process count
    func filteredCount(filter: ProcessFilter, searchText: String, hierarchical: Bool = true) -> Int {
        ensureFilterMemo(filter: filter, searchText: searchText, hierarchical: hierarchical)
        return filterMemoCount
    }

    private func ensureFilterMemo(filter: ProcessFilter, searchText: String, hierarchical: Bool) {
        let key = FilterMemoKey(refreshCount: refreshCount, filter: filter, searchText: searchText, hierarchical: hierarchical)
        if filterMemoKey == key { return }

        let lowercasedSearch = searchText.lowercased()
        let matches: (ProcessInfo) -> Bool = { [self] process in
            matchesFilter(process, filter: filter) &&
                matchesSearch(process, searchText: searchText, lowercasedSearch: lowercasedSearch)
        }

        var count = 0
        if hierarchical {
            filterMemoProcesses = ProcessFetcher.filterTree(processes) { process in
                let matched = matches(process)
                if matched { count += 1 }
                return matched
            }
        } else {
            var flat: [ProcessInfo] = []
            flat.reserveCapacity(flatProcesses.count)
            for proc in flatProcesses where matches(proc) {
                var flatProc = proc
                flatProc.children = []
                flat.append(flatProc)
            }
            count = flat.count
            filterMemoProcesses = flat
        }
        filterMemoCount = count
        filterMemoKey = key
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
            return process.isApp
        }
    }

    private func matchesSearch(_ process: ProcessInfo, searchText: String, lowercasedSearch: String) -> Bool {
        guard !searchText.isEmpty else { return true }

        // ProcessInfo precomputes lowercase fields once per fetch — avoids
        // re-lowercasing both name and command for every process on every
        // keystroke. Matching on the UTF-8 views uses the standard library's
        // collection search; `String.contains(_:)` with Foundation loaded routes
        // through NSString-style option parsing, which profiled ~10x slower.
        let needle = lowercasedSearch.utf8
        return process.lowercaseName.utf8.contains(needle) ||
            process.lowercaseCommand.utf8.contains(needle) ||
            String(process.id).utf8.contains(searchText.utf8)
    }
}
