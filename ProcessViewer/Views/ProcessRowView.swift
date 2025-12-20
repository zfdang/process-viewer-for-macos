import SwiftUI

/// Column configuration for process table
struct ColumnConfig {
    static let pidWidth: CGFloat = 70
    static let nameWidth: CGFloat = 220
    static let cpuWidth: CGFloat = 70
    static let userWidth: CGFloat = 90
    static let prioWidth: CGFloat = 70
    static let resMemWidth: CGFloat = 100
    static let virMemWidth: CGFloat = 100
    static let threadWidth: CGFloat = 70
    static let commandMinWidth: CGFloat = 250
    
    static let indentPerLevel: CGFloat = 20
}

/// Single row view for a process
struct ProcessRowView: View {
    let process: ProcessInfo
    let level: Int
    let isExpanded: Bool
    let hasChildren: Bool
    let isSelected: Bool
    let onToggleExpand: () -> Void
    
    var body: some View {
        HStack(spacing: 0) {
            // PID column
            Text("\(process.id)")
                .font(.system(.body, design: .monospaced))
                .frame(width: ColumnConfig.pidWidth, alignment: .trailing)
                .padding(.trailing, 8)
            
            // Name column with hierarchy indent
            HStack(spacing: 4) {
                // Indent spacer based on level
                if level > 0 {
                    Spacer()
                        .frame(width: CGFloat(level) * ColumnConfig.indentPerLevel)
                }
                
                // Expand/collapse indicator - CLICKABLE
                if hasChildren {
                    Button(action: onToggleExpand) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.secondary)
                            .frame(width: 16, height: 16)
                    }
                    .buttonStyle(.plain)
                    .contentShape(Rectangle())
                } else {
                    Circle()
                        .fill(Color.secondary.opacity(0.5))
                        .frame(width: 5, height: 5)
                        .frame(width: 16)
                }
                
                // Process name
                Text(process.name)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(width: ColumnConfig.nameWidth, alignment: .leading)
            
            // CPU column
            Text(String(format: "%.1f", process.cpuUsage))
                .font(.system(.body, design: .monospaced))
                .frame(width: ColumnConfig.cpuWidth, alignment: .trailing)
                .foregroundColor(cpuColor(process.cpuUsage))
            
            // User column
            Text(process.user)
                .lineLimit(1)
                .frame(width: ColumnConfig.userWidth, alignment: .leading)
                .padding(.leading, 8)
            
            // Priority/Nice column
            Text("\(process.priority)/\(process.nice)")
                .font(.system(.body, design: .monospaced))
                .frame(width: ColumnConfig.prioWidth, alignment: .center)
            
            // Resident Memory column
            Text(ProcessInfo.formatMemory(process.residentMemory))
                .font(.system(.body, design: .monospaced))
                .frame(width: ColumnConfig.resMemWidth, alignment: .trailing)
            
            // Virtual Memory column
            Text(ProcessInfo.formatMemory(process.virtualMemory))
                .font(.system(.body, design: .monospaced))
                .frame(width: ColumnConfig.virMemWidth, alignment: .trailing)
            
            // Threads column
            Text("\(process.threadCount)")
                .font(.system(.body, design: .monospaced))
                .frame(width: ColumnConfig.threadWidth, alignment: .trailing)
            
            // Command column
            Text(process.command)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(minWidth: ColumnConfig.commandMinWidth, alignment: .leading)
                .padding(.leading, 8)
            
            Spacer()
        }
        .padding(.vertical, 4)
        .background(isSelected ? Color.accentColor.opacity(0.2) : Color.clear)
    }
    
    /// Color code based on CPU usage
    private func cpuColor(_ usage: Double) -> Color {
        if usage > 50 {
            return .red
        } else if usage > 20 {
            return .orange
        } else if usage > 5 {
            return .yellow
        }
        return .primary
    }
}

/// Header row for the process table with sortable columns
struct ProcessHeaderView: View {
    @Binding var sortColumn: SortColumn
    @Binding var sortOrder: SortOrder
    
    var body: some View {
        HStack(spacing: 0) {
            SortableColumnHeader(title: "PID", column: .pid, width: ColumnConfig.pidWidth, 
                                 alignment: .trailing, sortColumn: $sortColumn, sortOrder: $sortOrder)
                .padding(.trailing, 8)
            
            SortableColumnHeader(title: "Name", column: .name, width: ColumnConfig.nameWidth,
                                 alignment: .leading, sortColumn: $sortColumn, sortOrder: $sortOrder)
            
            SortableColumnHeader(title: "CPU %", column: .cpu, width: ColumnConfig.cpuWidth,
                                 alignment: .trailing, sortColumn: $sortColumn, sortOrder: $sortOrder)
            
            SortableColumnHeader(title: "User", column: .user, width: ColumnConfig.userWidth,
                                 alignment: .leading, sortColumn: $sortColumn, sortOrder: $sortOrder)
                .padding(.leading, 8)
            
            SortableColumnHeader(title: "Pri/Nice", column: .priority, width: ColumnConfig.prioWidth,
                                 alignment: .center, sortColumn: $sortColumn, sortOrder: $sortOrder)
            
            SortableColumnHeader(title: "Res Mem", column: .resMem, width: ColumnConfig.resMemWidth,
                                 alignment: .trailing, sortColumn: $sortColumn, sortOrder: $sortOrder)
            
            SortableColumnHeader(title: "Vir Mem", column: .virMem, width: ColumnConfig.virMemWidth,
                                 alignment: .trailing, sortColumn: $sortColumn, sortOrder: $sortOrder)
            
            SortableColumnHeader(title: "Threads", column: .threads, width: ColumnConfig.threadWidth,
                                 alignment: .trailing, sortColumn: $sortColumn, sortOrder: $sortOrder)
            
            SortableColumnHeader(title: "Command", column: .command, width: ColumnConfig.commandMinWidth,
                                 alignment: .leading, sortColumn: $sortColumn, sortOrder: $sortOrder)
                .padding(.leading, 8)
            
            Spacer()
        }
        .font(.headline)
        .padding(.vertical, 6)
        .background(Color(NSColor.controlBackgroundColor))
    }
}

/// A single sortable column header
struct SortableColumnHeader: View {
    let title: String
    let column: SortColumn
    let width: CGFloat
    let alignment: Alignment
    @Binding var sortColumn: SortColumn
    @Binding var sortOrder: SortOrder
    
    private var isActive: Bool {
        sortColumn == column
    }
    
    var body: some View {
        Button(action: {
            if sortColumn == column {
                sortOrder.toggle()
            } else {
                sortColumn = column
                sortOrder = .ascending
            }
        }) {
            HStack(spacing: 4) {
                Text(title)
                if isActive {
                    Image(systemName: sortOrder == .ascending ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                }
            }
            .frame(width: width, alignment: alignment)
            .foregroundColor(isActive ? .accentColor : .primary)
        }
        .buttonStyle(.plain)
    }
}
