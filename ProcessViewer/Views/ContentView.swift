import SwiftUI

/// Main content view containing toolbar and process tree
struct ContentView: View {
    @StateObject private var monitor = ProcessMonitor()
    @State private var selectedFilter: ProcessFilter = .apps
    @State private var searchText = ""
    @State private var selectedProcess: ProcessInfo?
    @State private var outlineViewRef = OutlineViewReference()
    
    private var filteredProcesses: [ProcessInfo] {
        monitor.filteredProcesses(filter: selectedFilter, searchText: searchText)
    }
    
    private var filteredCount: Int {
        monitor.filteredCount(filter: selectedFilter, searchText: searchText)
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Toolbar with filter, search, and action buttons
            FilterToolbar(
                selectedFilter: $selectedFilter,
                searchText: $searchText,
                processCount: filteredCount,
                onRefresh: {
                    Task {
                        await monitor.refresh()
                    }
                },
                onExpandAll: {
                    outlineViewRef.expandAll()
                },
                onCollapseAll: {
                    outlineViewRef.collapseAll()
                }
            )
            
            Divider()
            
            // Process tree using NSOutlineView
            if monitor.isLoading && monitor.processes.isEmpty {
                ProgressView("Loading processes...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filteredProcesses.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)
                    Text("No processes found")
                        .font(.title2)
                        .foregroundColor(.secondary)
                    if !searchText.isEmpty {
                        Text("Try adjusting your search")
                            .font(.callout)
                            .foregroundColor(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProcessOutlineView(
                    processes: filteredProcesses,
                    selectedProcess: $selectedProcess,
                    outlineViewRef: outlineViewRef
                )
            }
            
            // Status bar
            HStack {
                if monitor.isLoading {
                    ProgressView()
                        .scaleEffect(0.5)
                        .frame(width: 16, height: 16)
                    Text("Refreshing...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                if let selected = selectedProcess {
                    Text("Selected: \(selected.name) (PID \(selected.id))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(Color(NSColor.controlBackgroundColor))
        }
        .frame(minWidth: 1000, minHeight: 600)
        .onAppear {
            // Start auto-refresh
            monitor.startAutoRefresh(interval: 3.0)
        }
        .onDisappear {
            // Stop auto-refresh to prevent crash on exit
            monitor.stopAutoRefresh()
        }
    }
}

#Preview {
    ContentView()
}
