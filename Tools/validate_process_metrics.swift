#!/usr/bin/env swift

import Foundation
import Darwin

private let procPidPathInfoMaxSize: Int32 = 4096
private let procPidListFds: Int32 = 1
private let procPidFdSocketInfo: Int32 = 3
private let proxFdTypeSocket: UInt32 = 2
private let procPidListFdSize = MemoryLayout<proc_fdinfo>.stride
private let procPidFdSocketInfoSize = MemoryLayout<socket_fdinfo>.stride

struct ProcessDescriptor {
    let pid: pid_t
    let user: String
    let command: String
}

struct TaskMetrics {
    let cpuPercent: Double
    let residentKB: Int
    let virtualKB: Int
    let priorityApprox: Int
    let nice: Int
}

struct PSSnapshot {
    let user: String
    let cpuPercent: Double
    let residentKB: Int
    let virtualKB: Int
    let priority: Int
    let nice: Int
    let command: String
}

struct ValidationRow {
    let pid: pid_t
    let command: String
    let cpuDiff: Double
    let residentDiffKB: Int
    let virtualDiffKB: Int
    let appPriorityApprox: Int
    let psPriority: Int
    let niceMatches: Bool
    let userMatches: Bool
    let connectionMatches: Bool?
}

func runCommand(_ launchPath: String, arguments: [String]) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: launchPath)
    process.arguments = arguments

    let stdout = Pipe()
    process.standardOutput = stdout
    process.standardError = Pipe()

    try process.run()
    process.waitUntilExit()

    let data = stdout.fileHandleForReading.readDataToEndOfFile()
    guard process.terminationStatus == 0 else {
        return ""
    }

    return String(decoding: data, as: UTF8.self)
}

func currentUsername() -> String {
    let uid = getuid()
    let configuredBufferSize = Int(sysconf(Int32(_SC_GETPW_R_SIZE_MAX)))
    let bufferSize = configuredBufferSize > 0 ? configuredBufferSize : 16_384

    var pwd = passwd()
    var result: UnsafeMutablePointer<passwd>?
    var buffer = [CChar](repeating: 0, count: bufferSize)

    guard getpwuid_r(uid, &pwd, &buffer, buffer.count, &result) == 0, result != nil else {
        return "unknown"
    }

    return String(cString: pwd.pw_name)
}

func username(for uid: uid_t, cache: inout [uid_t: String]) -> String {
    if let cached = cache[uid] {
        return cached
    }

    let configuredBufferSize = Int(sysconf(Int32(_SC_GETPW_R_SIZE_MAX)))
    let bufferSize = configuredBufferSize > 0 ? configuredBufferSize : 16_384

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

func enumerateProcesses() -> [ProcessDescriptor] {
    var descriptors: [ProcessDescriptor] = []
    var userCache: [uid_t: String] = [:]

    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
    var size = 0

    guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0 else {
        return descriptors
    }

    var procList = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride)
    guard sysctl(&mib, UInt32(mib.count), &procList, &size, nil, 0) == 0 else {
        return descriptors
    }

    let actualCount = size / MemoryLayout<kinfo_proc>.stride
    descriptors.reserveCapacity(actualCount)

    for proc in procList[0..<actualCount] {
        let pid = proc.kp_proc.p_pid
        guard pid != 0 else { continue }

        let fallbackName = withUnsafePointer(to: proc.kp_proc.p_comm) { ptr -> String in
            ptr.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN)) { cstr in
                String(cString: cstr)
            }
        }

        var pathBuffer = [CChar](repeating: 0, count: Int(procPidPathInfoMaxSize))
        let pathLength = proc_pidpath(pid, &pathBuffer, UInt32(procPidPathInfoMaxSize))
        let command = pathLength > 0 ? String(cString: pathBuffer) : fallbackName

        let uid = proc.kp_eproc.e_ucred.cr_uid
        let user = username(for: uid, cache: &userCache)
        descriptors.append(ProcessDescriptor(pid: pid, user: user, command: command))
    }

    return descriptors.sorted { $0.pid < $1.pid }
}

func taskInfo(for pid: pid_t) -> proc_taskinfo? {
    var info = proc_taskinfo()
    let size = MemoryLayout<proc_taskinfo>.size
    let ret = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, Int32(size))
    return ret == size ? info : nil
}

func sampleCPUPercent(for pid: pid_t, intervalSeconds: Double) -> (cpuPercent: Double, info: proc_taskinfo)? {
    guard let firstInfo = taskInfo(for: pid) else { return nil }
    let firstTime = mach_absolute_time()

    Thread.sleep(forTimeInterval: intervalSeconds)

    guard let secondInfo = taskInfo(for: pid) else { return nil }
    let secondTime = mach_absolute_time()

    let firstCPU = firstInfo.pti_total_user + firstInfo.pti_total_system
    let secondCPU = secondInfo.pti_total_user + secondInfo.pti_total_system
    guard secondCPU >= firstCPU, secondTime > firstTime else { return nil }

    let cpuPercent = (Double(secondCPU - firstCPU) / Double(secondTime - firstTime)) * 100.0
    return (cpuPercent, secondInfo)
}

func parsePSSnapshot(pid: pid_t) -> PSSnapshot? {
    guard let output = try? runCommand(
        "/bin/ps",
        arguments: ["-p", String(pid), "-o", "user=", "-o", "%cpu=", "-o", "rss=", "-o", "vsz=", "-o", "pri=", "-o", "nice=", "-o", "comm="]
    ) else {
        return nil
    }

    guard let line = output.split(whereSeparator: \.isNewline).first?.trimmingCharacters(in: .whitespacesAndNewlines),
          !line.isEmpty else {
        return nil
    }

    let parts = line.split(maxSplits: 6, whereSeparator: \.isWhitespace)
    guard parts.count == 7 else { return nil }

    return PSSnapshot(
        user: String(parts[0]),
        cpuPercent: Double(parts[1]) ?? 0,
        residentKB: Int(parts[2]) ?? 0,
        virtualKB: Int(parts[3]) ?? 0,
        priority: Int(parts[4]) ?? 0,
        nice: Int(parts[5]) ?? 0,
        command: String(parts[6])
    )
}

func isCountableNetworkSocket(_ info: socket_fdinfo) -> Bool {
    let family = info.psi.soi_family
    guard family == AF_INET || family == AF_INET6 else { return false }

    let socketType = info.psi.soi_type
    return socketType == SOCK_STREAM || socketType == SOCK_DGRAM
}

func connectionCount(for pid: pid_t) -> Int {
    let bufferSize = proc_pidinfo(pid, procPidListFds, 0, nil, 0)
    guard bufferSize > 0 else { return 0 }

    let fdCount = Int(bufferSize) / procPidListFdSize
    var fdInfos = [proc_fdinfo](repeating: proc_fdinfo(), count: fdCount)

    let actualSize = proc_pidinfo(pid, procPidListFds, 0, &fdInfos, bufferSize)
    guard actualSize > 0 else { return 0 }

    let actualCount = Int(actualSize) / procPidListFdSize
    var count = 0

    for fdInfo in fdInfos.prefix(actualCount) where fdInfo.proc_fdtype == proxFdTypeSocket {
        var socketInfo = socket_fdinfo()
        let result = proc_pidfdinfo(pid, fdInfo.proc_fd, procPidFdSocketInfo, &socketInfo, Int32(procPidFdSocketInfoSize))

        if result == Int32(procPidFdSocketInfoSize), isCountableNetworkSocket(socketInfo) {
            count += 1
        }
    }

    return count
}

func lsofConnectionCount(for pid: pid_t) -> Int? {
    guard let output = try? runCommand("/usr/sbin/lsof", arguments: ["-nP", "-a", "-p", String(pid), "-i", "-F", "n"]) else {
        return nil
    }

    return output.split(whereSeparator: \.isNewline).filter { $0.first == "n" }.count
}

func benchmark() {
    let processes = enumerateProcesses()
    let pids = processes.map(\.pid)

    func measure(_ label: String, block: () -> Int) {
        let start = DispatchTime.now().uptimeNanoseconds
        let count = block()
        let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        print("\(label): count=\(count) elapsed_ms=\(String(format: "%.2f", elapsedMs))")
    }

    print("Benchmarking \(pids.count) processes")

    measure("proc_pidpath") {
        var hits = 0
        for pid in pids {
            var pathBuffer = [CChar](repeating: 0, count: Int(procPidPathInfoMaxSize))
            if proc_pidpath(pid, &pathBuffer, UInt32(procPidPathInfoMaxSize)) > 0 {
                hits += 1
            }
        }
        return hits
    }

    measure("getpwuid_r(unique users)") {
        var cache: [uid_t: String] = [:]
        var hits = 0

        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0 else { return 0 }
        var procList = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride)
        guard sysctl(&mib, UInt32(mib.count), &procList, &size, nil, 0) == 0 else { return 0 }

        let actualCount = size / MemoryLayout<kinfo_proc>.stride
        for proc in procList[0..<actualCount] where proc.kp_proc.p_pid != 0 {
            let uid = proc.kp_eproc.e_ucred.cr_uid
            if cache[uid] == nil {
                cache[uid] = username(for: uid, cache: &cache)
                hits += 1
            }
        }

        return hits
    }

    measure("proc_pidinfo(PROC_PIDTASKINFO)") {
        var hits = 0
        for pid in pids where taskInfo(for: pid) != nil {
            hits += 1
        }
        return hits
    }

    measure("connectionCount(all)") {
        pids.reduce(0) { partial, pid in
            partial + connectionCount(for: pid)
        }
    }

    measure("steady_state_refresh_estimate") {
        var hits = 0
        let sampleTime = mach_absolute_time()

        for pid in pids {
            if let info = taskInfo(for: pid) {
                _ = info.pti_total_user + info.pti_total_system + sampleTime
                hits += 1
            }
        }

        return hits
    }
}

func validate(sampleCount: Int, intervalSeconds: Double, includeConnections: Bool) {
    let currentUser = currentUsername()
    let candidates = enumerateProcesses()
        .filter { $0.user == currentUser }
        .prefix(sampleCount)

    var rows: [ValidationRow] = []
    var skipped = 0

    for candidate in candidates {
        guard let sampled = sampleCPUPercent(for: candidate.pid, intervalSeconds: intervalSeconds),
              let psSnapshot = parsePSSnapshot(pid: candidate.pid) else {
            skipped += 1
            continue
        }

        let taskMetrics = TaskMetrics(
            cpuPercent: sampled.cpuPercent,
            residentKB: Int(sampled.info.pti_resident_size / 1024),
            virtualKB: Int(sampled.info.pti_virtual_size / 1024),
            priorityApprox: Int(sampled.info.pti_priority),
            nice: psSnapshot.nice
        )

        let appConnections = includeConnections ? connectionCount(for: candidate.pid) : 0
        let systemConnections = includeConnections ? lsofConnectionCount(for: candidate.pid) : nil

        rows.append(
            ValidationRow(
                pid: candidate.pid,
                command: candidate.command,
                cpuDiff: abs(taskMetrics.cpuPercent - psSnapshot.cpuPercent),
                residentDiffKB: abs(taskMetrics.residentKB - psSnapshot.residentKB),
                virtualDiffKB: abs(taskMetrics.virtualKB - psSnapshot.virtualKB),
                appPriorityApprox: taskMetrics.priorityApprox,
                psPriority: psSnapshot.priority,
                niceMatches: taskMetrics.nice == psSnapshot.nice,
                userMatches: candidate.user == psSnapshot.user,
                connectionMatches: includeConnections ? (systemConnections.map { $0 == appConnections }) : nil
            )
        )
    }

    print("Validated \(rows.count) processes, skipped \(skipped)")

    for row in rows {
        let connectionText: String
        if let connectionMatches = row.connectionMatches {
            connectionText = connectionMatches ? "ok" : "mismatch"
        } else {
            connectionText = "skipped"
        }

        print(
            """
            pid=\(row.pid) cpuDiff=\(String(format: "%.2f", row.cpuDiff)) \
            rssDiffKB=\(row.residentDiffKB) vszDiffKB=\(row.virtualDiffKB) \
            priorityApprox=\(row.appPriorityApprox) psPriority=\(row.psPriority) \
            nice=\(row.niceMatches ? "ok" : "mismatch") \
            user=\(row.userMatches ? "ok" : "mismatch") \
            connections=\(connectionText) \
            command=\(row.command)
            """
        )
    }

    guard !rows.isEmpty else { return }

    let maxCPUDiff = rows.map(\.cpuDiff).max() ?? 0
    let avgCPUDiff = rows.map(\.cpuDiff).reduce(0, +) / Double(rows.count)
    let maxResidentDiff = rows.map(\.residentDiffKB).max() ?? 0
    let maxVirtualDiff = rows.map(\.virtualDiffKB).max() ?? 0
    let priorityMatches = rows.filter { $0.appPriorityApprox == $0.psPriority }.count
    let connectionMatches = rows.compactMap(\.connectionMatches).filter { $0 }.count
    let connectionSamples = rows.compactMap(\.connectionMatches).count

    print("")
    print("Summary")
    print("avg_cpu_diff_pp=\(String(format: "%.2f", avgCPUDiff))")
    print("max_cpu_diff_pp=\(String(format: "%.2f", maxCPUDiff))")
    print("max_rss_diff_kb=\(maxResidentDiff)")
    print("max_vsz_diff_kb=\(maxVirtualDiff)")
    print("priority_approx_matches_ps=\(priorityMatches)/\(rows.count)")
    print("priority_note=ps_PRI_uses_Mach_scheduling_state_and_public_libproc_only_exposes_an_approximation")
    if connectionSamples > 0 {
        print("connection_matches=\(connectionMatches)/\(connectionSamples)")
    }
}

let args = Array(CommandLine.arguments.dropFirst())
let benchmarkMode = args.contains("--benchmark")
let skipConnections = args.contains("--skip-connections")

let sampleCount: Int = {
    if let sampleIndex = args.firstIndex(of: "--sample"),
       args.indices.contains(sampleIndex + 1) {
        return Int(args[sampleIndex + 1]) ?? 8
    }
    return 8
}()

let intervalSeconds: Double = {
    if let intervalIndex = args.firstIndex(of: "--interval"),
       args.indices.contains(intervalIndex + 1) {
        return Double(args[intervalIndex + 1]) ?? 1.0
    }
    return 1.0
}()

if benchmarkMode {
    benchmark()
    print("")
}

validate(sampleCount: sampleCount, intervalSeconds: intervalSeconds, includeConnections: !skipConnections)
