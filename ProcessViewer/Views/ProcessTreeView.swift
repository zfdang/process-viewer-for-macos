import SwiftUI

/// Sortable column identifier
enum SortColumn: String, CaseIterable {
    case pid = "PID"
    case name = "Name"
    case cpu = "CPU %"
    case user = "User"
    case priority = "Pri/Nice"
    case resMem = "Res Mem"
    case virMem = "Vir Mem"
    case threads = "Threads"
    case command = "Command"
}

/// Sort order
enum SortOrder {
    case ascending, descending
    
    mutating func toggle() {
        self = self == .ascending ? .descending : .ascending
    }
}

/// Tree view for displaying processes in hierarchy
struct ProcessTreeView: View {
    let processes: [ProcessInfo]
    @Binding var selectedProcess: ProcessInfo?
    @Binding var expandedProcesses: Set<pid_t>
    @Binding var sortColumn: SortColumn
    @Binding var sortOrder: SortOrder
    
    var body: some View {
        VStack(spacing: 0) {
            // Header with clickable columns for sorting
            ProcessHeaderView(sortColumn: $sortColumn, sortOrder: $sortOrder)
            
            Divider()
            
            // Process list
            ScrollView([.horizontal, .vertical]) {
                LazyVStack(spacing: 0, pinnedViews: []) {
                    ForEach(processes) { process in
                        ProcessTreeNode(
                            process: process,
                            level: 0,
                            selectedProcess: $selectedProcess,
                            expandedProcesses: $expandedProcesses
                        )
                    }
                }
                .frame(minWidth: 1200) // Ensure minimum width for all columns
            }
        }
    }
}

/// Recursive tree node for a single process and its children
struct ProcessTreeNode: View {
    let process: ProcessInfo
    let level: Int
    @Binding var selectedProcess: ProcessInfo?
    @Binding var expandedProcesses: Set<pid_t>
    
    private var isExpanded: Bool {
        expandedProcesses.contains(process.id)
    }
    
    private var isSelected: Bool {
        selectedProcess?.id == process.id
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Process row
            ProcessRowView(
                process: process,
                level: level,
                isExpanded: isExpanded,
                hasChildren: process.hasChildren,
                isSelected: isSelected,
                onToggleExpand: {
                    toggleExpanded()
                }
            )
            .contentShape(Rectangle())
            .background(rowBackground)
            .onTapGesture {
                selectedProcess = process
            }
            .contextMenu {
                Button("Copy Process Info") {
                    ProcessUtils.copyToClipboard(process)
                }
                
                Divider()
                
                if process.hasChildren {
                    Button(isExpanded ? "Collapse" : "Expand") {
                        toggleExpanded()
                    }
                    
                    Button("Expand All Children") {
                        expandAll(process)
                    }
                    
                    Button("Collapse All Children") {
                        collapseAll(process)
                    }
                }
            }
            
            // Children (if expanded)
            if isExpanded && process.hasChildren {
                ForEach(process.children) { child in
                    ProcessTreeNode(
                        process: child,
                        level: level + 1,
                        selectedProcess: $selectedProcess,
                        expandedProcesses: $expandedProcesses
                    )
                }
            }
        }
    }
    
    private var rowBackground: some View {
        Group {
            if isSelected {
                Color.accentColor.opacity(0.3)
            } else if level % 2 == 1 {
                Color(NSColor.controlBackgroundColor).opacity(0.5)
            } else {
                Color.clear
            }
        }
    }
    
    private func toggleExpanded() {
        withAnimation(.easeInOut(duration: 0.15)) {
            if isExpanded {
                expandedProcesses.remove(process.id)
            } else {
                expandedProcesses.insert(process.id)
            }
        }
    }
    
    private func expandAll(_ node: ProcessInfo) {
        expandedProcesses.insert(node.id)
        for child in node.children {
            expandAll(child)
        }
    }
    
    private func collapseAll(_ node: ProcessInfo) {
        expandedProcesses.remove(node.id)
        for child in node.children {
            collapseAll(child)
        }
    }
}
