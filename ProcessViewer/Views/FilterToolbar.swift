import SwiftUI

/// Filter toolbar with filter buttons, search field, and action buttons
struct FilterToolbar: View {
    @Binding var selectedFilter: ProcessFilter
    @Binding var searchText: String
    let processCount: Int
    let onRefresh: () -> Void
    let onExpandAll: () -> Void
    let onCollapseAll: () -> Void
    
    var body: some View {
        HStack(spacing: 12) {
            // Filter picker (Apps, My, System, All)
            Picker("Filter", selection: $selectedFilter) {
                ForEach(ProcessFilter.allCases) { filter in
                    Text(filter.rawValue).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 280)
            
            // Process count (next to filter)
            Text("\(processCount) processes")
                .foregroundColor(.secondary)
                .font(.callout)
            
            Spacer()
            
            // Search field (center-right area)
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("Search", text: $searchText)
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
            
            Divider()
                .frame(height: 16)
            
            // Action buttons (right side)
            HStack(spacing: 8) {
                // Expand All button - custom icon
                Button(action: onExpandAll) {
                    Image("ExpandAll")
                        .resizable()
                        .renderingMode(.template)
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.borderless)
                .help("Expand All")
                
                // Collapse All button - custom icon
                Button(action: onCollapseAll) {
                    Image("CollapseAll")
                        .resizable()
                        .renderingMode(.template)
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.borderless)
                .help("Collapse All")
                
                Divider()
                    .frame(height: 16)
                
                // Refresh button
                Button(action: onRefresh) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 14))
                }
                .buttonStyle(.borderless)
                .keyboardShortcut("r", modifiers: .command)
                .help("Refresh (⌘R)")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
