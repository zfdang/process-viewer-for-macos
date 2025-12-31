import Foundation

/// Represents a network connection (TCP or UDP)
struct NetworkConnection: Identifiable {
    let id = UUID()
    let fd: Int32
    let socketType: String // "TCP" or "UDP"
    let family: String     // "IPv4" or "IPv6"
    let localAddress: String
    let localPort: UInt16
    let remoteAddress: String
    let remotePort: UInt16
    let state: String      // TCP state (ESTABLISHED, LISTEN, etc.)
    
    var displayString: String {
        "\(socketType) \(localAddress):\(localPort) -> \(remoteAddress):\(remotePort) (\(state))"
    }
}
