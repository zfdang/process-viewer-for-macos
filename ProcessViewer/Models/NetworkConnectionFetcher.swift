import Foundation
import Darwin

/// Helper enum for fetching network connections for a process
enum NetworkConnectionFetcher {
    // libproc Constants (not available in Swift's Darwin module)
    private static let PROC_PIDLISTFDS: Int32 = 1
    private static let PROC_PIDFDSOCKETINFO: Int32 = 3
    private static let PROX_FDTYPE_SOCKET: UInt32 = 2
    private static let PROC_PIDLISTFD_SIZE = MemoryLayout<proc_fdinfo>.stride
    private static let PROC_PIDFDSOCKETINFO_SIZE = MemoryLayout<socket_fdinfo>.stride

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

    /// Get the count of network connections for a process
    static func connectionCount(for pid: pid_t) -> Int {
        let bufferSize = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bufferSize > 0 else { return 0 }
        
        let fdCount = bufferSize / Int32(PROC_PIDLISTFD_SIZE)
        var fdInfos = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(fdCount))
        
        let actualSize = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fdInfos, bufferSize)
        guard actualSize > 0 else { return 0 }
        
        let actualCount = Int(actualSize) / PROC_PIDLISTFD_SIZE
        var count = 0
        
        for i in 0..<actualCount {
            if fdInfos[i].proc_fdtype == PROX_FDTYPE_SOCKET {
                var socketInfo = socket_fdinfo()
                let result = proc_pidfdinfo(pid, fdInfos[i].proc_fd, PROC_PIDFDSOCKETINFO, &socketInfo, Int32(PROC_PIDFDSOCKETINFO_SIZE))
                if result == Int32(PROC_PIDFDSOCKETINFO_SIZE) {
                    let family = socketInfo.psi.soi_family
                    if family == AF_INET || family == AF_INET6 {
                        count += 1
                    }
                }
            }
        }
        return count
    }
    
    /// Fetch all network connections for a given PID
    static func fetchConnections(for pid: pid_t) -> [NetworkConnection] {
        var connections: [NetworkConnection] = []
        let bufferSize = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bufferSize > 0 else { return connections }
        
        let fdCount = bufferSize / Int32(PROC_PIDLISTFD_SIZE)
        var fdInfos = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(fdCount))
        let actualSize = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fdInfos, bufferSize)
        guard actualSize > 0 else { return connections }
        
        let actualCount = Int(actualSize) / PROC_PIDLISTFD_SIZE
        for i in 0..<actualCount {
            let fdInfo = fdInfos[i]
            guard fdInfo.proc_fdtype == PROX_FDTYPE_SOCKET else { continue }
            
            var socketInfo = socket_fdinfo()
            let socketInfoSize = proc_pidfdinfo(pid, fdInfo.proc_fd, PROC_PIDFDSOCKETINFO, &socketInfo, Int32(PROC_PIDFDSOCKETINFO_SIZE))
            guard socketInfoSize == Int32(PROC_PIDFDSOCKETINFO_SIZE) else { continue }
            
            let family = socketInfo.psi.soi_family
            guard family == AF_INET || family == AF_INET6 else { continue }
            
            let sockType = socketInfo.psi.soi_type
            guard sockType == SOCK_STREAM || sockType == SOCK_DGRAM else { continue }
            
            if let conn = parseSocketInfo(socketInfo, fd: fdInfo.proc_fd) {
                connections.append(conn)
            }
        }
        return connections
    }
    
    private static func parseSocketInfo(_ info: socket_fdinfo, fd: Int32) -> NetworkConnection? {
        let family = info.psi.soi_family
        let sockType = info.psi.soi_type
        let familyStr = family == AF_INET ? "IPv4" : "IPv6"
        let typeStr = sockType == SOCK_STREAM ? "TCP" : "UDP"
        
        var localAddr = ""
        var localPort: UInt16 = 0
        var remoteAddr = ""
        var remotePort: UInt16 = 0
        var state = ""
        
        if sockType == SOCK_STREAM {
            let tcpInfo = info.psi.soi_proto.pri_tcp
            state = tcpStateString(tcpInfo.tcpsi_state)
            if family == AF_INET {
                let insi = tcpInfo.tcpsi_ini
                localAddr = ipv4ToString(insi.insi_laddr.ina_46.i46a_addr4.s_addr)
                localPort = UInt16(bigEndian: UInt16(truncatingIfNeeded: insi.insi_lport))
                remoteAddr = ipv4ToString(insi.insi_faddr.ina_46.i46a_addr4.s_addr)
                remotePort = UInt16(bigEndian: UInt16(truncatingIfNeeded: insi.insi_fport))
            } else {
                let insi = tcpInfo.tcpsi_ini
                localAddr = ipv6ToString(insi.insi_laddr.ina_6)
                localPort = UInt16(bigEndian: UInt16(truncatingIfNeeded: insi.insi_lport))
                remoteAddr = ipv6ToString(insi.insi_faddr.ina_6)
                remotePort = UInt16(bigEndian: UInt16(truncatingIfNeeded: insi.insi_fport))
            }
        } else {
            state = "UDP"
            if family == AF_INET {
                let insi = info.psi.soi_proto.pri_in
                localAddr = ipv4ToString(insi.insi_laddr.ina_46.i46a_addr4.s_addr)
                localPort = UInt16(bigEndian: UInt16(truncatingIfNeeded: insi.insi_lport))
                remoteAddr = ipv4ToString(insi.insi_faddr.ina_46.i46a_addr4.s_addr)
                remotePort = UInt16(bigEndian: UInt16(truncatingIfNeeded: insi.insi_fport))
            } else {
                let insi = info.psi.soi_proto.pri_in
                localAddr = ipv6ToString(insi.insi_laddr.ina_6)
                localPort = UInt16(bigEndian: UInt16(truncatingIfNeeded: insi.insi_lport))
                remoteAddr = ipv6ToString(insi.insi_faddr.ina_6)
                remotePort = UInt16(bigEndian: UInt16(truncatingIfNeeded: insi.insi_fport))
            }
        }
        
        if localAddr == "0.0.0.0" && localPort == 0 && remoteAddr == "0.0.0.0" && remotePort == 0 { 
            return nil 
        }
        
        // Clean up 0.0.0.0 display for remote
        if remoteAddr == "0.0.0.0" && remotePort == 0 {
            remoteAddr = "*"
        }
        
        return NetworkConnection(
            fd: fd,
            socketType: typeStr,
            family: familyStr,
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
