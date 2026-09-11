import Foundation
import Darwin

/// Result of counting a process's network sockets.
enum ConnectionCountResult: Equatable {
    /// The process's descriptor table was readable and `count` sockets matched.
    case count(Int)
    /// The kernel refused to expose this process's descriptors (EPERM). Only a
    /// root / setuid tool such as `lsof` can inspect other users' processes, so
    /// the UI should render this as "unknown" rather than a misleading zero.
    case unavailable
}

/// Helper enum for fetching network connections for a process
enum NetworkConnectionFetcher {
    // libproc Constants (not available in Swift's Darwin module)
    private static let PROC_PIDLISTFDS: Int32 = 1
    private static let PROC_PIDFDSOCKETINFO: Int32 = 3
    private static let PROX_FDTYPE_SOCKET: UInt32 = 2
    private static let PROC_PIDLISTFD_SIZE = MemoryLayout<proc_fdinfo>.stride
    private static let PROC_PIDFDSOCKETINFO_SIZE = MemoryLayout<socket_fdinfo>.stride
    // `INI_IPV4` from <sys/proc_info.h>: set in `insi_vflag` when an AF_INET6
    // socket is actually carrying IPv4 traffic (v4-mapped addresses). `netstat`
    // and `lsof` consult this flag to pick the address representation.
    private static let INI_IPV4: UInt8 = 0x1

    // Descriptors can be opened between the size query and the copy. Over-allocate
    // by this many entries (the same trick lsof uses) so a growing fd table is not
    // silently truncated on the second call.
    private static let fdListSlack = 32

    // TCP states
    private static let TCPS_CLOSED: Int32 = 0
    private static let TCPS_LISTEN: Int32 = 1
    private static let TCPS_SYN_SENT: Int32 = 2
    private static let TCPS_SYN_RECEIVED: Int32 = 3
    private static let TCPS_ESTABLISHED: Int32 = 4
    private static let TCPS_CLOSE_WAIT: Int32 = 5
    private static let TCPS_FIN_WAIT_1: Int32 = 6
    private static let TCPS_CLOSING: Int32 = 7
    private static let TCPS_LAST_ACK: Int32 = 8
    private static let TCPS_FIN_WAIT_2: Int32 = 9
    private static let TCPS_TIME_WAIT: Int32 = 10

    /// Get the count of network connections for a process.
    ///
    /// Uses exactly the same inclusion rule as `fetchConnections(for:)` so the
    /// number in the process table always equals the number of rows the detail
    /// window will show.
    static func connectionCount(for pid: pid_t) -> ConnectionCountResult {
        switch listFileDescriptors(for: pid) {
        case .unavailable:
            return .unavailable
        case .descriptors(let fdInfos):
            var count = 0
            for fdInfo in fdInfos where fdInfo.proc_fdtype == PROX_FDTYPE_SOCKET {
                var socketInfo = socket_fdinfo()
                let result = proc_pidfdinfo(pid, fdInfo.proc_fd, PROC_PIDFDSOCKETINFO, &socketInfo, Int32(PROC_PIDFDSOCKETINFO_SIZE))
                if result == Int32(PROC_PIDFDSOCKETINFO_SIZE), isDisplayableNetworkSocket(socketInfo) {
                    count += 1
                }
            }
            return .count(count)
        }
    }

    /// Fetch all network connections for a given PID
    static func fetchConnections(for pid: pid_t) -> [NetworkConnection] {
        guard case .descriptors(let fdInfos) = listFileDescriptors(for: pid) else { return [] }

        var connections: [NetworkConnection] = []
        for fdInfo in fdInfos where fdInfo.proc_fdtype == PROX_FDTYPE_SOCKET {
            var socketInfo = socket_fdinfo()
            let socketInfoSize = proc_pidfdinfo(pid, fdInfo.proc_fd, PROC_PIDFDSOCKETINFO, &socketInfo, Int32(PROC_PIDFDSOCKETINFO_SIZE))
            guard socketInfoSize == Int32(PROC_PIDFDSOCKETINFO_SIZE),
                  isDisplayableNetworkSocket(socketInfo) else { continue }

            connections.append(parseSocketInfo(socketInfo, fd: fdInfo.proc_fd))
        }
        return connections
    }

    // MARK: - Descriptor listing

    private enum DescriptorList {
        case descriptors([proc_fdinfo])
        case unavailable
    }

    private static func listFileDescriptors(for pid: pid_t) -> DescriptorList {
        errno = 0
        let bufferSize = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bufferSize > 0 else {
            // proc_pidinfo returns 0 and sets errno on failure. EPERM means the
            // process belongs to another user; ESRCH means it already exited.
            // Anything else (including a genuinely empty table) counts as zero.
            return errno == EPERM ? .unavailable : .descriptors([])
        }

        let capacity = Int(bufferSize) / PROC_PIDLISTFD_SIZE + fdListSlack
        var fdInfos = [proc_fdinfo](repeating: proc_fdinfo(), count: capacity)
        errno = 0
        let actualSize = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fdInfos, Int32(capacity * PROC_PIDLISTFD_SIZE))
        guard actualSize > 0 else {
            return errno == EPERM ? .unavailable : .descriptors([])
        }

        fdInfos.removeSubrange((Int(actualSize) / PROC_PIDLISTFD_SIZE)...)
        return .descriptors(fdInfos)
    }

    // MARK: - Socket classification

    /// Whether a socket should be counted and listed as a network connection:
    /// any IPv4/IPv6 TCP or UDP socket. Sockets that are not yet bound or
    /// connected are included and rendered as `*:*`, which is exactly what
    /// `lsof -i` and `netstat -an` report for them — so the number in the
    /// table matches those tools and the rows in the detail window.
    private static func isDisplayableNetworkSocket(_ info: socket_fdinfo) -> Bool {
        let family = info.psi.soi_family
        guard family == AF_INET || family == AF_INET6 else { return false }

        let socketType = info.psi.soi_type
        return socketType == SOCK_STREAM || socketType == SOCK_DGRAM
    }

    private static func usesIPv4Representation(_ insi: in_sockinfo, family: Int32) -> Bool {
        family == AF_INET || (insi.insi_vflag & INI_IPV4) != 0
    }

    private static func isZero(_ addr: in6_addr) -> Bool {
        withUnsafeBytes(of: addr) { bytes in bytes.allSatisfy { $0 == 0 } }
    }

    // MARK: - Parsing

    private static func parseSocketInfo(_ info: socket_fdinfo, fd: Int32) -> NetworkConnection {
        let family = info.psi.soi_family
        let sockType = info.psi.soi_type
        let typeStr = sockType == SOCK_STREAM ? "TCP" : "UDP"

        let insi: in_sockinfo
        let state: String
        if sockType == SOCK_STREAM {
            let tcpInfo = info.psi.soi_proto.pri_tcp
            insi = tcpInfo.tcpsi_ini
            state = tcpStateString(tcpInfo.tcpsi_state)
        } else {
            insi = info.psi.soi_proto.pri_in
            state = "UDP"
        }

        let ipv4 = usesIPv4Representation(insi, family: family)
        let localPort = UInt16(bigEndian: UInt16(truncatingIfNeeded: insi.insi_lport))
        let remotePort = UInt16(bigEndian: UInt16(truncatingIfNeeded: insi.insi_fport))

        // An all-zero address means "any address" (a listener bound to every
        // interface, or an unconnected socket with no peer). Render it as "*"
        // the way netstat and lsof do (`*:8080`, `*:*`) instead of 0.0.0.0 / ::.
        func endpoint(_ addr: in_addr_t, _ addr6: in6_addr) -> String {
            let zero = ipv4 ? addr == 0 : isZero(addr6)
            if zero { return "*" }
            return ipv4 ? ipv4ToString(addr) : ipv6ToString(addr6)
        }
        let localAddr = endpoint(insi.insi_laddr.ina_46.i46a_addr4.s_addr, insi.insi_laddr.ina_6)
        let remoteAddr = endpoint(insi.insi_faddr.ina_46.i46a_addr4.s_addr, insi.insi_faddr.ina_6)

        return NetworkConnection(
            fd: fd,
            socketType: typeStr,
            family: ipv4 ? "IPv4" : "IPv6",
            localAddress: localAddr,
            localPort: localPort,
            remoteAddress: remoteAddr,
            remotePort: remotePort,
            state: state
        )
    }

    private static func ipv4ToString(_ addr: in_addr_t) -> String {
        var addrCopy = addr
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        inet_ntop(AF_INET, &addrCopy, &buffer, socklen_t(INET_ADDRSTRLEN))
        return String(cString: buffer)
    }

    private static func ipv6ToString(_ addr: in6_addr) -> String {
        var addrCopy = addr
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        inet_ntop(AF_INET6, &addrCopy, &buffer, socklen_t(INET6_ADDRSTRLEN))
        return String(cString: buffer)
    }

    private static func tcpStateString(_ state: Int32) -> String {
        switch state {
        case TCPS_CLOSED: return "CLOSED"
        case TCPS_LISTEN: return "LISTEN"
        case TCPS_SYN_SENT: return "SYN_SENT"
        case TCPS_SYN_RECEIVED: return "SYN_RCVD"
        case TCPS_ESTABLISHED: return "ESTABLISHED"
        case TCPS_CLOSE_WAIT: return "CLOSE_WAIT"
        case TCPS_FIN_WAIT_1: return "FIN_WAIT_1"
        case TCPS_CLOSING: return "CLOSING"
        case TCPS_LAST_ACK: return "LAST_ACK"
        case TCPS_FIN_WAIT_2: return "FIN_WAIT_2"
        case TCPS_TIME_WAIT: return "TIME_WAIT"
        default: return "UNKNOWN"
        }
    }
}
