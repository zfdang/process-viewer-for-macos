import SwiftUI
import AppKit

// MARK: - Outline View Reference

/// Reference class to allow external control of NSOutlineView expand/collapse
class OutlineViewReference: ObservableObject {
    weak var outlineView: NSOutlineView?
    
    func expandAll() {
        outlineView?.expandItem(nil, expandChildren: true)
    }
    
    func collapseAll() {
        outlineView?.collapseItem(nil, collapseChildren: true)
    }
}

// MARK: - Process Node Wrapper (for NSOutlineView)

/// Wrapper class for ProcessInfo to work with NSOutlineView (requires reference types)
class ProcessNode: NSObject {
    let process: ProcessInfo
    var children: [ProcessNode]
    weak var parent: ProcessNode?
    
    init(process: ProcessInfo, parent: ProcessNode? = nil) {
        self.process = process
        self.parent = parent
        self.children = []
        super.init()
        self.children = process.children.map { ProcessNode(process: $0, parent: self) }
    }
    
    var isExpandable: Bool {
        !children.isEmpty
    }
}

// MARK: - Column Identifiers

extension NSUserInterfaceItemIdentifier {
    static let pidColumn = NSUserInterfaceItemIdentifier("PIDColumn")
    static let nameColumn = NSUserInterfaceItemIdentifier("NameColumn")
    static let cpuColumn = NSUserInterfaceItemIdentifier("CPUColumn")
    static let userColumn = NSUserInterfaceItemIdentifier("UserColumn")
    static let priorityColumn = NSUserInterfaceItemIdentifier("PriorityColumn")
    static let resMemColumn = NSUserInterfaceItemIdentifier("ResMemColumn")
    static let virMemColumn = NSUserInterfaceItemIdentifier("VirMemColumn")
    static let threadsColumn = NSUserInterfaceItemIdentifier("ThreadsColumn")
    static let commandColumn = NSUserInterfaceItemIdentifier("CommandColumn")
}

// MARK: - NSOutlineView Representable

struct ProcessOutlineView: NSViewRepresentable {
    let processes: [ProcessInfo]
    @Binding var selectedProcess: ProcessInfo?
    var outlineViewRef: OutlineViewReference
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        
        let outlineView = NSOutlineView()
        outlineView.style = .plain
        outlineView.rowSizeStyle = .medium  // Increased row height
        outlineView.rowHeight = 24  // Explicit row height
        outlineView.usesAlternatingRowBackgroundColors = true
        outlineView.allowsMultipleSelection = false
        outlineView.allowsColumnReordering = true
        outlineView.allowsColumnResizing = true
        outlineView.allowsColumnSelection = false
        outlineView.autosaveTableColumns = true
        outlineView.autosaveName = "ProcessViewerOutlineView"
        outlineView.autosaveExpandedItems = true
        
        // Create columns
        let columns: [(NSUserInterfaceItemIdentifier, String, CGFloat, CGFloat, CGFloat)] = [
            (.pidColumn, "PID", 70, 50, 100),
            (.nameColumn, "Name", 200, 100, 400),
            (.cpuColumn, "CPU %", 70, 50, 100),
            (.userColumn, "User", 90, 60, 150),
            (.priorityColumn, "Pri/Nice", 70, 50, 100),
            (.resMemColumn, "Res Mem", 100, 70, 150),
            (.virMemColumn, "Vir Mem", 100, 70, 150),
            (.threadsColumn, "Threads", 70, 50, 100),
            (.commandColumn, "Command", 300, 150, 1000),
        ]
        
        for (identifier, title, width, minWidth, maxWidth) in columns {
            let column = NSTableColumn(identifier: identifier)
            column.title = title
            column.width = width
            column.minWidth = minWidth
            column.maxWidth = maxWidth
            column.isEditable = false
            column.sortDescriptorPrototype = NSSortDescriptor(key: identifier.rawValue, ascending: true)
            
            // Name column is the outline column (shows disclosure triangles)
            if identifier == .nameColumn {
                outlineView.outlineTableColumn = column
            }
            
            outlineView.addTableColumn(column)
        }
        
        outlineView.delegate = context.coordinator
        outlineView.dataSource = context.coordinator
        
        // Set up double-click for expand/collapse
        outlineView.doubleAction = #selector(Coordinator.doubleClickAction(_:))
        outlineView.target = context.coordinator
        
        // Context menu
        let menu = NSMenu()
        menu.delegate = context.coordinator
        
        let copyItem = NSMenuItem(title: "Copy Process Info", action: #selector(Coordinator.copyProcessInfo(_:)), keyEquivalent: "c")
        copyItem.target = context.coordinator
        menu.addItem(copyItem)
        
        menu.addItem(NSMenuItem.separator())
        
        let expandItem = NSMenuItem(title: "Expand All", action: #selector(Coordinator.expandAll(_:)), keyEquivalent: "")
        expandItem.target = context.coordinator
        menu.addItem(expandItem)
        
        let collapseItem = NSMenuItem(title: "Collapse All", action: #selector(Coordinator.collapseAll(_:)), keyEquivalent: "")
        collapseItem.target = context.coordinator
        menu.addItem(collapseItem)
        
        outlineView.menu = menu
        
        scrollView.documentView = outlineView
        
        context.coordinator.outlineView = outlineView
        
        // Default sort by Name
        outlineView.sortDescriptors = [NSSortDescriptor(key: "NameColumn", ascending: true)]
        
        // Set reference for external control
        outlineViewRef.outlineView = outlineView
        
        return scrollView
    }
    
    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let outlineView = nsView.documentView as? NSOutlineView else { return }
        
        // Save scroll position
        let scrollPosition = nsView.contentView.bounds.origin
        
        // Save current expanded state (by PID)
        let expandedPIDs = context.coordinator.getExpandedPIDs()
        
        // Save current selection (by PID)
        let selectedPID = context.coordinator.getSelectedPID()
        
        // Update data
        context.coordinator.rootNodes = processes.map { ProcessNode(process: $0) }
        context.coordinator.parent = self
        
        // Reload data
        outlineView.reloadData()
        
        // Restore expanded state
        context.coordinator.restoreExpandedState(expandedPIDs)
        
        // Restore selection
        if let pid = selectedPID {
            context.coordinator.restoreSelection(pid)
        }
        
        // Restore scroll position
        nsView.contentView.scroll(to: scrollPosition)
        nsView.reflectScrolledClipView(nsView.contentView)
        
        // Update reference
        outlineViewRef.outlineView = outlineView
    }
    
    // MARK: - Coordinator
    
    class Coordinator: NSObject, NSOutlineViewDelegate, NSOutlineViewDataSource, NSMenuDelegate {
        var parent: ProcessOutlineView
        var rootNodes: [ProcessNode] = []
        weak var outlineView: NSOutlineView?
        
        // Track expanded state - initialized with first level expanded
        private var expandedPIDs: Set<pid_t> = []
        private var hasInitialized = false
        
        init(_ parent: ProcessOutlineView) {
            self.parent = parent
            self.rootNodes = parent.processes.map { ProcessNode(process: $0) }
        }
        
        // MARK: - State Preservation
        
        func getExpandedPIDs() -> Set<pid_t> {
            guard let outlineView = outlineView else { return expandedPIDs }
            
            var pids = Set<pid_t>()
            collectExpandedPIDs(from: rootNodes, outlineView: outlineView, into: &pids)
            return pids
        }
        
        private func collectExpandedPIDs(from nodes: [ProcessNode], outlineView: NSOutlineView, into pids: inout Set<pid_t>) {
            for node in nodes {
                if outlineView.isItemExpanded(node) {
                    pids.insert(node.process.id)
                }
                collectExpandedPIDs(from: node.children, outlineView: outlineView, into: &pids)
            }
        }
        
        func restoreExpandedState(_ pids: Set<pid_t>) {
            guard let outlineView = outlineView else { return }
            
            if pids.isEmpty && !hasInitialized {
                // First time - expand first level
                for node in rootNodes {
                    outlineView.expandItem(node, expandChildren: false)
                }
                hasInitialized = true
            } else {
                // Restore previous state
                expandNodes(rootNodes, outlineView: outlineView, expandedPIDs: pids)
            }
            
            expandedPIDs = pids
        }
        
        private func expandNodes(_ nodes: [ProcessNode], outlineView: NSOutlineView, expandedPIDs: Set<pid_t>) {
            for node in nodes {
                if expandedPIDs.contains(node.process.id) {
                    outlineView.expandItem(node, expandChildren: false)
                }
                expandNodes(node.children, outlineView: outlineView, expandedPIDs: expandedPIDs)
            }
        }
        
        func getSelectedPID() -> pid_t? {
            guard let outlineView = outlineView else { return nil }
            let row = outlineView.selectedRow
            if row >= 0, let node = outlineView.item(atRow: row) as? ProcessNode {
                return node.process.id
            }
            return nil
        }
        
        func restoreSelection(_ pid: pid_t) {
            guard let outlineView = outlineView else { return }
            
            // Find the row with matching PID
            for row in 0..<outlineView.numberOfRows {
                if let node = outlineView.item(atRow: row) as? ProcessNode,
                   node.process.id == pid {
                    outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                    break
                }
            }
        }
        
        // MARK: - NSOutlineViewDataSource
        
        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            if let node = item as? ProcessNode {
                return node.children.count
            }
            return rootNodes.count
        }
        
        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            if let node = item as? ProcessNode {
                return node.children[index]
            }
            return rootNodes[index]
        }
        
        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            if let node = item as? ProcessNode {
                return node.isExpandable
            }
            return false
        }
        
        // For autosaveExpandedItems
        func outlineView(_ outlineView: NSOutlineView, persistentObjectForItem item: Any?) -> Any? {
            if let node = item as? ProcessNode {
                return node.process.id
            }
            return nil
        }
        
        func outlineView(_ outlineView: NSOutlineView, itemForPersistentObject object: Any) -> Any? {
            guard let pid = object as? pid_t else { return nil }
            return findNode(withPID: pid, in: rootNodes)
        }
        
        private func findNode(withPID pid: pid_t, in nodes: [ProcessNode]) -> ProcessNode? {
            for node in nodes {
                if node.process.id == pid {
                    return node
                }
                if let found = findNode(withPID: pid, in: node.children) {
                    return found
                }
            }
            return nil
        }
        
        // MARK: - NSOutlineViewDelegate
        
        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let node = item as? ProcessNode, let column = tableColumn else { return nil }
            
            let process = node.process
            let identifier = column.identifier
            
            let cellView = outlineView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView
                ?? createCellView(identifier: identifier)
            
            let textField = cellView.textField!
            textField.font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            textField.textColor = .labelColor
            
            switch identifier {
            case .pidColumn:
                textField.stringValue = "\(process.id)"
                textField.alignment = .right
            case .nameColumn:
                textField.stringValue = process.name
                textField.alignment = .left
                textField.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
                // Set app icon
                if let imageView = cellView.imageView {
                    if let icon = getAppIcon(for: process) {
                        imageView.image = icon
                    } else {
                        // Generic executable icon
                        imageView.image = NSWorkspace.shared.icon(forFile: "/usr/bin/env")
                    }
                }
            case .cpuColumn:
                textField.stringValue = String(format: "%.1f", process.cpuUsage)
                textField.alignment = .right
                textField.textColor = cpuColor(process.cpuUsage)
            case .userColumn:
                textField.stringValue = process.user
                textField.alignment = .left
                textField.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
            case .priorityColumn:
                textField.stringValue = "\(process.priority)/\(process.nice)"
                textField.alignment = .center
            case .resMemColumn:
                textField.stringValue = ProcessInfo.formatMemory(process.residentMemory)
                textField.alignment = .right
            case .virMemColumn:
                textField.stringValue = ProcessInfo.formatMemory(process.virtualMemory)
                textField.alignment = .right
            case .threadsColumn:
                textField.stringValue = "\(process.threadCount)"
                textField.alignment = .right
            case .commandColumn:
                textField.stringValue = process.command
                textField.alignment = .left
                textField.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
                textField.lineBreakMode = .byTruncatingMiddle
            default:
                textField.stringValue = ""
            }
            
            return cellView
        }
        
        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard let outlineView = notification.object as? NSOutlineView else { return }
            let selectedRow = outlineView.selectedRow
            if selectedRow >= 0, let node = outlineView.item(atRow: selectedRow) as? ProcessNode {
                parent.selectedProcess = node.process
            } else {
                parent.selectedProcess = nil
            }
        }
        
        // Sortable columns
        func outlineView(_ outlineView: NSOutlineView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard let sortDescriptor = outlineView.sortDescriptors.first else { return }
            
            // Save state before sorting
            let expandedPIDs = getExpandedPIDs()
            let selectedPID = getSelectedPID()
            
            sortNodes(&rootNodes, by: sortDescriptor)
            outlineView.reloadData()
            
            // Restore state after sorting
            restoreExpandedState(expandedPIDs)
            if let pid = selectedPID {
                restoreSelection(pid)
            }
        }
        
        private func sortNodes(_ nodes: inout [ProcessNode], by descriptor: NSSortDescriptor) {
            let ascending = descriptor.ascending
            let key = descriptor.key ?? ""
            
            nodes.sort { a, b in
                let result: Bool
                switch key {
                case "PIDColumn":
                    result = a.process.id < b.process.id
                case "NameColumn":
                    result = a.process.name.localizedCaseInsensitiveCompare(b.process.name) == .orderedAscending
                case "CPUColumn":
                    result = a.process.cpuUsage < b.process.cpuUsage
                case "UserColumn":
                    result = a.process.user.localizedCaseInsensitiveCompare(b.process.user) == .orderedAscending
                case "PriorityColumn":
                    result = a.process.priority < b.process.priority
                case "ResMemColumn":
                    result = a.process.residentMemory < b.process.residentMemory
                case "VirMemColumn":
                    result = a.process.virtualMemory < b.process.virtualMemory
                case "ThreadsColumn":
                    result = a.process.threadCount < b.process.threadCount
                case "CommandColumn":
                    result = a.process.command.localizedCaseInsensitiveCompare(b.process.command) == .orderedAscending
                default:
                    result = a.process.id < b.process.id
                }
                return ascending ? result : !result
            }
            
            // Sort children recursively
            for i in 0..<nodes.count {
                sortNodes(&nodes[i].children, by: descriptor)
            }
        }
        
        // MARK: - Helper Methods
        
        private func createCellView(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
            let cellView = NSTableCellView()
            cellView.identifier = identifier
            
            let textField = NSTextField(labelWithString: "")
            textField.lineBreakMode = .byTruncatingTail
            textField.translatesAutoresizingMaskIntoConstraints = false
            
            cellView.addSubview(textField)
            cellView.textField = textField
            
            // Name column gets an image view for app icon
            if identifier == .nameColumn {
                let imageView = NSImageView()
                imageView.translatesAutoresizingMaskIntoConstraints = false
                imageView.imageScaling = .scaleProportionallyUpOrDown
                cellView.addSubview(imageView)
                cellView.imageView = imageView
                
                NSLayoutConstraint.activate([
                    imageView.leadingAnchor.constraint(equalTo: cellView.leadingAnchor, constant: 2),
                    imageView.centerYAnchor.constraint(equalTo: cellView.centerYAnchor),
                    imageView.widthAnchor.constraint(equalToConstant: 18),
                    imageView.heightAnchor.constraint(equalToConstant: 18),
                    textField.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 4),
                    textField.trailingAnchor.constraint(equalTo: cellView.trailingAnchor, constant: -4),
                    textField.centerYAnchor.constraint(equalTo: cellView.centerYAnchor),
                ])
            } else {
                NSLayoutConstraint.activate([
                    textField.leadingAnchor.constraint(equalTo: cellView.leadingAnchor, constant: 4),
                    textField.trailingAnchor.constraint(equalTo: cellView.trailingAnchor, constant: -4),
                    textField.centerYAnchor.constraint(equalTo: cellView.centerYAnchor),
                ])
            }
            
            return cellView
        }
        
        /// Get app icon for a process
        private func getAppIcon(for process: ProcessInfo) -> NSImage? {
            let path = process.command
            
            // Try to find .app bundle
            if let range = path.range(of: ".app") {
                let appPath = String(path[..<range.upperBound])
                return NSWorkspace.shared.icon(forFile: appPath)
            }
            
            // For non-app executables, return generic icon
            return nil
        }
        
        private func cpuColor(_ usage: Double) -> NSColor {
            if usage > 50 {
                return .systemRed
            } else if usage > 20 {
                return .systemOrange
            } else if usage > 5 {
                return .systemYellow
            }
            return .labelColor
        }
        
        // MARK: - Actions
        
        @objc func doubleClickAction(_ sender: NSOutlineView) {
            let row = sender.clickedRow
            guard row >= 0, let node = sender.item(atRow: row) as? ProcessNode else { return }
            
            if sender.isItemExpanded(node) {
                sender.collapseItem(node)
            } else {
                sender.expandItem(node)
            }
        }
        
        @objc func copyProcessInfo(_ sender: Any?) {
            guard let outlineView = outlineView else { return }
            let row = outlineView.clickedRow >= 0 ? outlineView.clickedRow : outlineView.selectedRow
            guard row >= 0, let node = outlineView.item(atRow: row) as? ProcessNode else { return }
            
            ProcessUtils.copyToClipboard(node.process)
        }
        
        @objc func expandAll(_ sender: Any?) {
            outlineView?.expandItem(nil, expandChildren: true)
        }
        
        @objc func collapseAll(_ sender: Any?) {
            outlineView?.collapseItem(nil, collapseChildren: true)
        }
    }
}
