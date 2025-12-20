# Process Viewer

A native macOS application for viewing and monitoring system processes with a hierarchical tree display.

![macOS](https://img.shields.io/badge/macOS-13.0+-blue)
![Swift](https://img.shields.io/badge/Swift-5.0-orange)
![License](https://img.shields.io/badge/License-MIT-green)
[![Build and Release](https://github.com/zfdang/process-viewer-for-macos/actions/workflows/build-release.yml/badge.svg)](https://github.com/zfdang/process-viewer-for-macos/actions/workflows/build-release.yml)

## Screenshots

![Main Interface](docs/interface.png)

![Search](docs/interface-search.png)

## Features

- **Hierarchical Process Tree**: View processes in a parent-child tree structure
- **Flat View Mode**: Toggle between hierarchy and flat list view
- **Resizable Columns**: Drag column borders to adjust width
- **Sortable Columns**: Click column headers to sort
- **Process Filtering**: Filter by Apps / My Processes / System / All
- **Search**: Real-time search by name, command, or PID
- **Auto Refresh**: Automatic 3-second refresh with state preservation
- **App Icons**: Displays application icons for .app processes
- **Adjustable Row Size**: Choose between Small, Medium, or Large row heights
- **Expand/Collapse All**: Quick buttons to expand or collapse the entire tree
- **Copy Info**: Right-click to copy detailed process information
- **State Preservation**: Maintains scroll position, selection, and expanded state across refreshes

## Process Information Displayed

| Column | Description |
|--------|-------------|
| PID | Process ID |
| Name | Process name with app icon |
| CPU % | CPU usage (color-coded) |
| User | Owner username |
| Pri/Nice | Priority and nice value |
| Res Mem | Resident memory usage |
| Vir Mem | Virtual memory usage |
| Threads | Thread count |
| Command | Full executable path |

## Requirements

- macOS 13.0 or later
- Xcode 15.0 or later (for building from source)

## Installation

### Download Release

1. Go to [Releases](https://github.com/zfdang/process-viewer-for-macos/releases)
2. Download the latest DMG or ZIP file
3. Open the DMG and drag "Process Viewer" to Applications, or extract the ZIP
4. Right-click the app and select "Open" (first time only, to bypass Gatekeeper)

### Build from Source

1. Clone the repository:
   ```bash
   git clone https://github.com/zfdang/process-viewer-for-macos.git
   ```

2. Open in Xcode:
   ```bash
   cd process-viewer-for-macos
   open ProcessViewer.xcodeproj
   ```

3. Build and run (⌘R)

## Keyboard Shortcuts

| Shortcut | Action |
|----------|--------|
| ⌘R | Refresh process list |

## Note on Permissions

This app requires **disabled App Sandbox** to read all system process information. Without this, it would only see a limited subset of processes.

## Tech Stack

- **SwiftUI**: Application structure and toolbar
- **AppKit (NSOutlineView)**: Process tree with resizable/sortable columns
- **sysctl / libproc**: System APIs for process information

## License

MIT License - see [LICENSE](LICENSE) for details.

## Author

- **zfdang** - [GitHub](https://github.com/zfdang)

## Links

- [Website](https://proc.zfdang.com)
- [GitHub Repository](https://github.com/zfdang/process-viewer-for-macos)
- [Report Issues](https://github.com/zfdang/process-viewer-for-macos/issues)
