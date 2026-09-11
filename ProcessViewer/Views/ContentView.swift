import SwiftUI

/// Main content view containing toolbar and process tree
struct ContentView: View {
    @StateObject private var monitor = ProcessMonitor()
    @State private var selectedFilter: ProcessFilter = .apps
    @State private var searchText = ""
    @State private var selectedProcess: ProcessInfo?
    @State private var outlineViewRef = OutlineViewReference()
    @State private var rowSize: RowSize = .medium
    @State private var showHierarchy: Bool = true
    @State private var showCopiedToast: Bool = false
    
    @EnvironmentObject private var localization: L
    
    var body: some View {
        // Both values come from one memoized pass inside the monitor; reading
        // them once here keeps body evaluation cheap even when SwiftUI runs it
        // several times per refresh.
        let filteredProcesses = monitor.filteredProcesses(filter: selectedFilter, searchText: searchText, hierarchical: showHierarchy)
        let filteredCount = monitor.filteredCount(filter: selectedFilter, searchText: searchText, hierarchical: showHierarchy)

        ZStack {
            VStack(spacing: 0) {
                // Toolbar with filter, search, and action buttons
                FilterToolbar(
                    selectedFilter: $selectedFilter,
                    searchText: $searchText,
                    rowSize: $rowSize,
                    showHierarchy: $showHierarchy,
                    processCount: filteredCount,
                    onRefresh: {
                        Task {
                            await monitor.refresh(userInitiated: true)
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
                    ProgressView(L.s("loading"))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if filteredProcesses.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 48))
                            .foregroundColor(.secondary)
                        Text(L.s("noProcesses"))
                            .font(.title2)
                            .foregroundColor(.secondary)
                        if !searchText.isEmpty {
                            Text(L.s("adjustSearch"))
                                .font(.callout)
                                .foregroundColor(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ProcessOutlineView(
                        processes: filteredProcesses,
                        selectedProcess: $selectedProcess,
                        outlineViewRef: outlineViewRef,
                        rowSize: rowSize,
                        showHierarchy: $showHierarchy,
                        refreshTrigger: monitor.refreshCount,
                        filterKey: "\(selectedFilter.rawValue)-\(searchText)"
                    )
                    .id("\(rowSize.rawValue)-\(localization.isChinese)")
                }
                
                // Status bar
                HStack {
                    if monitor.isLoading {
                        ProgressView()
                            .scaleEffect(0.5)
                            .frame(width: 16, height: 16)
                        Text(L.s("refreshing"))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    Spacer()
                    
                    if let selected = selectedProcess {
                        Text("\(L.s("selected")): \(selected.name) (PID \(selected.id))")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(Color(NSColor.controlBackgroundColor))
            }
            
            // Toast overlay
            if showCopiedToast {
                VStack {
                    Spacer()
                    Text(L.s("copied"))
                        .font(.headline)
                        .foregroundColor(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(Color.black.opacity(0.75))
                        .cornerRadius(8)
                        .padding(.bottom, 60)
                }
                .transition(.opacity)
                .animation(.easeInOut(duration: 0.3), value: showCopiedToast)
            }
        }
        .frame(minWidth: 1000, minHeight: 600)
        .background(WindowVisibilityObserver { visible in
            monitor.setWindowVisible(visible)
        })
        .onAppear {
            // Start auto-refresh
            monitor.startAutoRefresh(interval: 5.0)
        }
        .onDisappear {
            // Stop auto-refresh to prevent crash on exit
            monitor.stopAutoRefresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: .processCopied)) { _ in
            showCopiedToast = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                showCopiedToast = false
            }
        }
    }
}

// MARK: - Window Visibility

/// Zero-size helper view that reports whether its hosting window is actually
/// on screen (not hidden, minimized, or fully covered by other windows). The
/// monitor uses this to suspend sampling while nobody can see the table.
private struct WindowVisibilityObserver: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> ObserverView {
        let view = ObserverView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ nsView: ObserverView, context: Context) {
        nsView.onChange = onChange
    }

    final class ObserverView: NSView {
        var onChange: ((Bool) -> Void)?
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers.removeAll()

            guard let window = window else { return }
            let center = NotificationCenter.default
            let windowNames: [Notification.Name] = [
                NSWindow.didChangeOcclusionStateNotification,
                NSWindow.didMiniaturizeNotification,
                NSWindow.didDeminiaturizeNotification,
                // Belt and braces for the initial appearance: the view can join
                // the window before it is ordered on screen, and becoming key /
                // main is a second, independent signal that it now is.
                NSWindow.didBecomeKeyNotification,
                NSWindow.didBecomeMainNotification,
            ]
            for name in windowNames {
                observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    self?.report()
                })
            }
            observers.append(center.addObserver(forName: NSApplication.didUnhideNotification, object: nil, queue: .main) { [weak self] _ in
                self?.report()
            })
            report()
        }

        private func report() {
            guard let window = window else { return }
            let visible = window.occlusionState.contains(.visible) && !window.isMiniaturized
            onChange?(visible)
        }

        deinit {
            observers.forEach(NotificationCenter.default.removeObserver)
        }
    }
}

#if !DISABLE_PREVIEW
#Preview {
    ContentView()
}
#endif
