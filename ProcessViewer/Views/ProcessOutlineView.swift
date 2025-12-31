import SwiftUI
import AppKit

// MARK: - Outline View Reference

/// Reference class to allow external control of NSOutlineView expand/collapse
class OutlineViewReference: ObservableObject {
    weak var outlineView: NSOutlineView?
    
    /// Expand all items in the tree
    func expandAll() {
        outlineView?.expandItem(nil, expandChildren: true)
    }
    
    /// Collapse all children but keep root items (first level) expanded
    func collapseAll() {
        guard let outlineView = outlineView else { return }
        
        // Get the number of root items
        let rootCount = outlineView.numberOfChildren(ofItem: nil)
        
        // For each root item, collapse its children but keep the root expanded
        for i in 0..<rootCount {
            if let rootItem = outlineView.child(i, ofItem: nil) {
                // Collapse all children of this root item
                outlineView.collapseItem(rootItem, collapseChildren: true)
                // Keep the root item itself expanded (show first level)
                outlineView.expandItem(rootItem, expandChildren: false)
            }
        }
    }
}

// MARK: - Process Node Wrapper (for NSOutlineView)

/// Wrapper class for ProcessInfo to work with NSOutlineView (requires reference types)
class ProcessNode: NSObject {
    let process: ProcessInfo
    var children: [ProcessNode]
    
    init(process: ProcessInfo) {
        self.process = process
        self.children = []
        super.init()
        self.children = process.children.map { ProcessNode(process: $0) }
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
    static let connectionsColumn = NSUserInterfaceItemIdentifier("ConnectionsColumn")
    static let commandColumn = NSUserInterfaceItemIdentifier("CommandColumn")
}

// MARK: - NSOutlineView Representable

struct ProcessOutlineView: NSViewRepresentable {
    let processes: [ProcessInfo]
    @Binding var selectedProcess: ProcessInfo?
    var outlineViewRef: OutlineViewReference
    var rowSize: RowSize = .medium
    @Binding var showHierarchy: Bool
    var refreshTrigger: Int = 0  // Changes to this value will trigger updateNSView
    var filterKey: String = ""   // Changes when filter/search changes
    
    /// Get row height based on size setting
    private var rowHeight: CGFloat {
        switch rowSize {
        case .small: return 20
        case .medium: return 26
        case .large: return 32
        }
    }
    
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
        outlineView.rowSizeStyle = .custom  // Use custom to allow explicit rowHeight
        outlineView.rowHeight = rowHeight
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
            (.pidColumn, L.s("col.pid"), 60, 50, 100),
            (.nameColumn, L.s("col.name"), 180, 80, 500),
            (.cpuColumn, L.s("col.cpu"), 60, 50, 100),
            (.userColumn, L.s("col.user"), 80, 60, 150),
            (.priorityColumn, L.s("col.prio"), 65, 50, 100),
            (.resMemColumn, L.s("col.resMem"), 90, 70, 150),
            (.virMemColumn, L.s("col.virMem"), 90, 70, 150),
            (.threadsColumn, L.s("col.threads"), 50, 40, 100),
            (.connectionsColumn, L.s("col.connections"), 50, 40, 80),
            (.commandColumn, L.s("col.command"), 500, 200, 2000),
        ]
        
        for (identifier, title, width, minWidth, maxWidth) in columns {
            let column = NSTableColumn(identifier: identifier)
            column.title = title
            column.width = width
            column.minWidth = minWidth
            column.maxWidth = maxWidth
            column.isEditable = false
            
            // Set header alignment based on column type
            switch identifier {
            case .pidColumn, .resMemColumn, .virMemColumn:
                column.headerCell.alignment = .right
            case .cpuColumn, .priorityColumn, .threadsColumn, .connectionsColumn:
                column.headerCell.alignment = .center
            default:
                column.headerCell.alignment = .left
            }
            
            // Numeric columns (CPU, Memory, Priority, Threads) default to descending (show highest first)
            let defaultDescending: Set<NSUserInterfaceItemIdentifier> = [
                .cpuColumn, .resMemColumn, .virMemColumn, .priorityColumn, .threadsColumn, .connectionsColumn
            ]
            let ascending = !defaultDescending.contains(identifier)
            column.sortDescriptorPrototype = NSSortDescriptor(key: identifier.rawValue, ascending: ascending)
            
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
        
        let copyNameItem = NSMenuItem(title: L.s("copyName"), action: #selector(Coordinator.copyProcessName(_:)), keyEquivalent: "1")
        copyNameItem.target = context.coordinator
        menu.addItem(copyNameItem)
        
        let copyCommandItem = NSMenuItem(title: L.s("copyCommand"), action: #selector(Coordinator.copyProcessCommand(_:)), keyEquivalent: "2")
        copyCommandItem.target = context.coordinator
        menu.addItem(copyCommandItem)
        
        let copyAllItem = NSMenuItem(title: L.s("copyAllInfo"), action: #selector(Coordinator.copyAllInfo(_:)), keyEquivalent: "3")
        copyAllItem.target = context.coordinator
        menu.addItem(copyAllItem)
        
        let searchItem = NSMenuItem(title: L.s("searchOnline"), action: #selector(Coordinator.searchOnline(_:)), keyEquivalent: "4")
        searchItem.target = context.coordinator
        menu.addItem(searchItem)
        
        let networkItem = NSMenuItem(title: L.s("viewNetworkConnections"), action: #selector(Coordinator.viewNetworkConnections(_:)), keyEquivalent: "5")
        networkItem.target = context.coordinator
        menu.addItem(networkItem)
        
        menu.addItem(NSMenuItem.separator())
        
        let expandItem = NSMenuItem(title: L.s("expandChildren"), action: #selector(Coordinator.expandAll(_:)), keyEquivalent: "")
        expandItem.target = context.coordinator
        menu.addItem(expandItem)
        
        let collapseItem = NSMenuItem(title: L.s("collapseChildren"), action: #selector(Coordinator.collapseAll(_:)), keyEquivalent: "")
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
        
        let isFirstLoad = !context.coordinator.hasInitialized
        
        // Detect switching from flat to hierarchy view
        let switchedToHierarchy = showHierarchy && !context.coordinator.lastShowHierarchy
        context.coordinator.lastShowHierarchy = showHierarchy
        
        context.coordinator.withStatePreservation {
            // Update data
            context.coordinator.rootNodes = processes.map { ProcessNode(process: $0) }
            context.coordinator.parent = self
            
            // Apply current sort descriptor to new data
            if let sortDescriptor = outlineView.sortDescriptors.first {
                context.coordinator.applySortDescriptor(sortDescriptor)
            }
            
            // Reload data
            outlineView.reloadData()
            
            if isFirstLoad {
                // First load - expand all nodes
                outlineView.expandItem(nil, expandChildren: true)
                context.coordinator.hasInitialized = true
            } else if switchedToHierarchy {
                // Switched from flat to hierarchy - expand first level
                for node in context.coordinator.rootNodes {
                    outlineView.expandItem(node, expandChildren: false)
                }
            }
        }
        
        // Update reference
        outlineViewRef.outlineView = outlineView
    }
    
    // MARK: - Coordinator
    
    class Coordinator: NSObject, NSOutlineViewDelegate, NSOutlineViewDataSource, NSMenuDelegate {
        var parent: ProcessOutlineView
        var rootNodes: [ProcessNode] = []
        weak var outlineView: NSOutlineView?
        
        // Track if view has been initialized (for first load expand all)
        var hasInitialized = false
        
        // Track last hierarchy state to detect flat->hierarchy switch
        var lastShowHierarchy = true
        
        // Cache for app icons to avoid repeated disk access
        private var iconCache: [String: NSImage] = [:]
        private let defaultIcon: NSImage = NSWorkspace.shared.icon(forFile: "/usr/bin/env")
        
        init(_ parent: ProcessOutlineView) {
            self.parent = parent
            self.rootNodes = parent.processes.map { ProcessNode(process: $0) }
        }
        
        // MARK: - State Preservation
        
        func getExpandedPIDs() -> Set<pid_t> {
            guard let outlineView = outlineView else { return [] }
            
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
            expandNodes(rootNodes, outlineView: outlineView, expandedPIDs: pids)
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
        
        /// Encapsulates saving and restoring outline view state (expanded nodes, selection, scroll position)
        func withStatePreservation(_ block: () -> Void) {
            guard let outlineView = outlineView,
                  let scrollView = outlineView.enclosingScrollView else {
                block()
                return
            }
            
            // Save state
            let scrollPosition = scrollView.contentView.bounds.origin
            let expandedPIDs = getExpandedPIDs()
            let selectedPID = getSelectedPID()
            
            block()
            
            // Restore state
            restoreExpandedState(expandedPIDs)
            if let pid = selectedPID {
                restoreSelection(pid)
            }
            scrollView.contentView.scroll(to: scrollPosition)
            scrollView.reflectScrolledClipView(scrollView.contentView)
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
            
            let cellView = outlineView.makeView(withIdentifier: identifier, owner: self) 
                ?? createCellView(identifier: identifier)
            
            if identifier == .connectionsColumn {
                if let button = cellView as? NSButton {
                    let count = process.connectionCount
                    button.title = "\(count)"
                    button.tag = Int(process.id)
                    button.contentTintColor = count > 0 ? .linkColor : .labelColor
                }
                return cellView
            }

            guard let tableCell = cellView as? NSTableCellView, let textField = tableCell.textField else {
                return cellView
            }
            
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
                // Set app icon (cached)
                if let imageView = tableCell.imageView {
                    imageView.image = getAppIcon(for: process)
                }
            case .cpuColumn:
                textField.stringValue = String(format: "%.1f", process.cpuUsage)
                textField.alignment = .center
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
                textField.alignment = .center
            case .connectionsColumn:
                break // Handled above
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
            
            // Wrap in async to avoid "Modifying state during view update" warning
            DispatchQueue.main.async { [weak self] in
                if selectedRow >= 0, let node = outlineView.item(atRow: selectedRow) as? ProcessNode {
                    self?.parent.selectedProcess = node.process
                } else {
                    self?.parent.selectedProcess = nil
                }
            }
        }
        
        /// Apply sort descriptor to current nodes (used on initial load)
        func applySortDescriptor(_ descriptor: NSSortDescriptor) {
            sortNodes(&rootNodes, by: descriptor)
        }
        
        // Sortable columns
        func outlineView(_ outlineView: NSOutlineView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard let sortDescriptor = outlineView.sortDescriptors.first else { return }
            
            // Auto switch to flat view only when user manually changes to a different column
            // Skip if oldDescriptors is empty (initial setup) or if same column (just toggling direction)
            let oldKey = oldDescriptors.first?.key
            let newKey = sortDescriptor.key
            if oldKey != nil && oldKey != newKey {
                // Switch to flat view - SwiftUI will trigger updateNSView with new data
                DispatchQueue.main.async { [weak self] in
                    self?.parent.showHierarchy = false
                }
            }
            
            // Sort current data immediately with state preservation
            withStatePreservation {
                sortNodes(&rootNodes, by: sortDescriptor)
                outlineView.reloadData()
                outlineView.needsDisplay = true
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
                case "ConnectionsColumn":
                    result = a.process.connectionCount < b.process.connectionCount
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
        
        private func createCellView(identifier: NSUserInterfaceItemIdentifier) -> NSView {
            if identifier == .connectionsColumn {
                let button = NSButton(title: "", target: self, action: #selector(viewNetworkConnectionsFromButton(_:)))
                button.isBordered = false
                button.alignment = .center
                button.font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
                button.identifier = identifier
                return button
            }
            
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
        
        /// Get app icon for a process (with caching)
        private func getAppIcon(for process: ProcessInfo) -> NSImage {
            let path = process.command
            
            // Check cache first
            if let cachedIcon = iconCache[path] {
                return cachedIcon
            }
            
            // Try to get icon using standard utility
            if let icon = ProcessUtils.getAppIcon(for: path) {
                iconCache[path] = icon
                return icon
            }
            
            // Fallback to default icon
            iconCache[path] = defaultIcon
            return defaultIcon
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
        
        @objc func copyProcessName(_ sender: Any?) {
            guard let outlineView = outlineView else { return }
            let row = outlineView.clickedRow >= 0 ? outlineView.clickedRow : outlineView.selectedRow
            guard row >= 0, let node = outlineView.item(atRow: row) as? ProcessNode else { return }
            
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(node.process.name, forType: .string)
            NotificationCenter.default.post(name: .processCopied, object: nil)
        }
        
        @objc func copyProcessCommand(_ sender: Any?) {
            guard let outlineView = outlineView else { return }
            let row = outlineView.clickedRow >= 0 ? outlineView.clickedRow : outlineView.selectedRow
            guard row >= 0, let node = outlineView.item(atRow: row) as? ProcessNode else { return }
            
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(node.process.command, forType: .string)
            NotificationCenter.default.post(name: .processCopied, object: nil)
        }
        
        @objc func copyAllInfo(_ sender: Any?) {
            guard let outlineView = outlineView else { return }
            let row = outlineView.clickedRow >= 0 ? outlineView.clickedRow : outlineView.selectedRow
            guard row >= 0, let node = outlineView.item(atRow: row) as? ProcessNode else { return }
            
            ProcessUtils.copyToClipboard(node.process)
        }
        
        @objc func searchOnline(_ sender: Any?) {
            guard let outlineView = outlineView else { return }
            let row = outlineView.clickedRow >= 0 ? outlineView.clickedRow : outlineView.selectedRow
            guard row >= 0, let node = outlineView.item(atRow: row) as? ProcessNode else { return }
            
            let processName = node.process.name
            let query = "macos process \(processName)"
            if let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
               let url = URL(string: "https://www.bing.com/search?q=\(encoded)") {
                NSWorkspace.shared.open(url)
            }
        }
        
        @objc func viewNetworkConnections(_ sender: Any?) {
            guard let outlineView = outlineView else { return }
            let row = outlineView.clickedRow >= 0 ? outlineView.clickedRow : outlineView.selectedRow
            guard row >= 0, let node = outlineView.item(atRow: row) as? ProcessNode else { return }
            
            showNetworkDetails(for: node.process)
        }
        
        @objc func viewNetworkConnectionsFromButton(_ sender: NSButton) {
            let pid = pid_t(sender.tag)
            // Find process info from rootNodes
            if let node = findNode(withPID: pid, in: rootNodes) {
                showNetworkDetails(for: node.process)
            }
        }
        
        private let networkWindowController = NetworkConnectionsWindowController()
        
        private func showNetworkDetails(for process: ProcessInfo) {
            networkWindowController.show(for: process.name, pid: process.id)
        }
        
        @objc func expandAll(_ sender: Any?) {
            guard let outlineView = outlineView else { return }
            // Context menu: operate on clicked/selected item only
            let row = outlineView.clickedRow >= 0 ? outlineView.clickedRow : outlineView.selectedRow
            if row >= 0, let item = outlineView.item(atRow: row) {
                outlineView.expandItem(item, expandChildren: true)
            }
        }
        
        @objc func collapseAll(_ sender: Any?) {
            guard let outlineView = outlineView else { return }
            // Context menu: operate on clicked/selected item only
            let row = outlineView.clickedRow >= 0 ? outlineView.clickedRow : outlineView.selectedRow
            if row >= 0, let item = outlineView.item(atRow: row) {
                outlineView.collapseItem(item, collapseChildren: true)
            }
        }
    }
}
