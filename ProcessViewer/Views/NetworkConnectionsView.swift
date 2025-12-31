import SwiftUI

/// View displaying detailed network connections for a process
struct NetworkConnectionsView: View {
    let processName: String
    let pid: pid_t
    let connections: [NetworkConnection]
    
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("\(L.s("net.title")) - \(processName) (PID \(pid))")
                    .font(.headline)
                Spacer()
                Text("\(connections.count) \(L.s("net.connections"))")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))
            
            Divider()
            
            // Connections Table
            if connections.isEmpty {
                VStack(spacing: 20) {
                    Image(systemName: "network.badge.shield.half.filled")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)
                    Text(L.s("net.noConnections"))
                        .font(.title3)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(connections) {
                    TableColumn(L.s("net.col.proto")) { conn in
                        Text(conn.socketType).frame(maxWidth: .infinity, alignment: .center)
                    }
                    .width(min: 50, ideal: 60)
                    
                    TableColumn(L.s("net.col.family")) { conn in
                        Text(conn.family).frame(maxWidth: .infinity, alignment: .center)
                    }
                    .width(min: 50, ideal: 60)
                    
                    TableColumn(L.s("net.col.localAddr"), value: \.localAddress)
                        .width(min: 100, ideal: 200)
                    
                    TableColumn(L.s("net.col.localPort")) { conn in
                        Text("\(conn.localPort)").frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .width(min: 60, ideal: 80)
                    
                    TableColumn(L.s("net.col.remoteAddr"), value: \.remoteAddress)
                        .width(min: 100, ideal: 200)
                    
                    TableColumn(L.s("net.col.remotePort")) { conn in
                        Text("\(conn.remotePort)").frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .width(min: 60, ideal: 86)
                    
                    TableColumn(L.s("net.col.state")) { conn in
                        Text(conn.state).frame(maxWidth: .infinity, alignment: .center)
                    }
                    .width(min: 80, ideal: 100)
                }
            }
            
            Divider()
            
            // Footer
            HStack {
                Spacer()
                Button(L.s("close")) {
                    dismiss()
                }
                .keyboardShortcut(.escape, modifiers: [])
                .padding()
            }
            .background(Color(NSColor.windowBackgroundColor))
        }
        .frame(minWidth: 900, minHeight: 450)
    }
}

// MARK: - Window Controller for Network Connections

/// Responsible for showing the network connections dialog in a separate window
class NetworkConnectionsWindowController {
    private var window: NSWindow?
    
    func show(for processName: String, pid: pid_t) {
        let connections = NetworkConnectionFetcher.fetchConnections(for: pid)
        
        let contentView = NetworkConnectionsView(
            processName: processName,
            pid: pid,
            connections: connections
        )
        
        let hostingController = NSHostingController(rootView: contentView)
        
        let window = NSWindow(contentViewController: hostingController)
        window.title = "\(L.s("net.title")) - \(processName)"
        window.styleMask = [NSWindow.StyleMask.titled, .closable, .resizable]
        window.setContentSize(NSSize(width: 1000, height: 600))
        window.center()
        window.makeKeyAndOrderFront(nil)
        
        self.window = window
    }
}
