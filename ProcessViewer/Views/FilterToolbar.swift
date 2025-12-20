import SwiftUI

/// Row size for the outline view
enum RowSize: String, CaseIterable {
    case small = "S"
    case medium = "M"
    case large = "L"
}

/// Filter toolbar with filter buttons, search field, and action buttons
struct FilterToolbar: View {
    @Binding var selectedFilter: ProcessFilter
    @Binding var searchText: String
    @Binding var rowSize: RowSize
    @Binding var showHierarchy: Bool
    let processCount: Int
    let onRefresh: () -> Void
    let onExpandAll: () -> Void
    let onCollapseAll: () -> Void
    
    @EnvironmentObject private var localization: L
    
    var body: some View {
        ZStack {
            // Center: Search field (truly centered)
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField(L.s("search"), text: $searchText)
                    .textFieldStyle(.plain)
                    .frame(width: 150)
                
                if !searchText.isEmpty {
                    Button(action: { searchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding(6)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(6)
            
            // Left and Right sections
            HStack(spacing: 12) {
                // Left section: Filter picker and process count
                HStack(spacing: 8) {
                    Picker(L.s("filter"), selection: $selectedFilter) {
                        ForEach(ProcessFilter.allCases) { filter in
                            Text(filter.localizedName).tag(filter)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 280)
                    .id("filter-picker-\(localization.isChinese)")
                    
                    Text("\(processCount) \(L.s("processes"))")
                        .foregroundColor(.secondary)
                        .font(.callout)
                }
                
                Spacer()
                
                // Right section: Action buttons
                HStack(spacing: 8) {
                    // Hierarchy toggle button
                    Button(action: { showHierarchy.toggle() }) {
                        Image("HierarchyView")
                            .resizable()
                            .renderingMode(.template)
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.borderless)
                    .background(showHierarchy ? Color.accentColor.opacity(0.2) : Color.clear)
                    .cornerRadius(4)
                    .help(showHierarchy ? L.s("switchToFlat") : L.s("switchToHierarchy"))
                    
                    // Expand All button
                    Button(action: onExpandAll) {
                        Image("ExpandAll")
                            .resizable()
                            .renderingMode(.template)
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.borderless)
                    .disabled(!showHierarchy)
                    .opacity(showHierarchy ? 1.0 : 0.4)
                    .help(L.s("expandAll"))
                    
                    // Collapse All button
                    Button(action: onCollapseAll) {
                        Image("CollapseAll")
                            .resizable()
                            .renderingMode(.template)
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.borderless)
                    .disabled(!showHierarchy)
                    .opacity(showHierarchy ? 1.0 : 0.4)
                    .help(L.s("collapseAll"))
                    
                    Divider()
                        .frame(height: 16)
                    
                    // Refresh button
                    Button(action: onRefresh) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 14))
                    }
                    .buttonStyle(.borderless)
                    .keyboardShortcut("r", modifiers: .command)
                    .help("\(L.s("refresh")) (⌘R)")
                    
                    Divider()
                        .frame(height: 16)
                    
                    // Row size buttons (Small, Medium, Large)
                    HStack(spacing: 4) {
                        ForEach(RowSize.allCases, id: \.self) { size in
                            Button(action: { rowSize = size }) {
                                Text(size.rawValue)
                                    .font(.system(size: 13, weight: rowSize == size ? .bold : .regular))
                                    .frame(width: 24, height: 24)
                            }
                            .buttonStyle(.borderless)
                            .background(rowSize == size ? Color.accentColor.opacity(0.2) : Color.clear)
                            .cornerRadius(4)
                            .help(size == .small ? L.s("rowSmall") : size == .medium ? L.s("rowMedium") : L.s("rowLarge"))
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
