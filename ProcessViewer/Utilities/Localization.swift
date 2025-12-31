import Foundation
import SwiftUI

/// Language options
enum AppLanguage: String, CaseIterable, Identifiable {
    case auto = "auto"
    case english = "en"
    case chinese = "zh"
    
    var id: String { rawValue }
    
    var displayName: String {
        switch self {
        case .auto: return L.isChinese ? "自动" : "Auto"
        case .english: return "English"
        case .chinese: return "简体中文"
        }
    }
}

/// Global localization manager
class L: ObservableObject {
    static let shared = L()
    
    @AppStorage("appLanguage") var preference: AppLanguage = .auto {
        didSet { objectWillChange.send() }
    }
    
    /// Whether we're currently using Chinese
    var isChinese: Bool {
        switch preference {
        case .auto: return Self.isSystemChinese
        case .english: return false
        case .chinese: return true
        }
    }
    
    static var isChinese: Bool { shared.isChinese }
    
    /// Check if system prefers Chinese
    private static var isSystemChinese: Bool {
        Locale.preferredLanguages.first?.contains("zh") ?? false
    }
    
    // MARK: - String Tables
    
    private static let strings: [String: (en: String, zh: String)] = [
        // Filters
        "filter.all": ("All", "全部"),
        "filter.apps": ("Apps", "应用"),
        "filter.my": ("My", "我的"),
        "filter.system": ("System", "系统"),
        
        // Toolbar
        "search": ("Search", "搜索"),
        "filter": ("Filter", "过滤"),
        "processes": ("processes", "个进程"),
        "refresh": ("Refresh", "刷新"),
        "expandAll": ("Expand All", "展开全部"),
        "collapseAll": ("Collapse All", "折叠全部"),
        "switchToFlat": ("Switch to Flat View", "切换到平铺视图"),
        "switchToHierarchy": ("Switch to Hierarchy View", "切换到层级视图"),
        "rowSmall": ("Small rows", "小行高"),
        "rowMedium": ("Medium rows", "中行高"),
        "rowLarge": ("Large rows", "大行高"),
        
        // Columns
        "col.pid": ("PID", "进程 ID"),
        "col.name": ("Name", "名称"),
        "col.cpu": ("CPU %", "CPU %"),
        "col.user": ("User", "用户"),
        "col.prio": ("Pri/Nice", "优先级"),
        "col.resMem": ("Res Mem", "常驻内存"),
        "col.virMem": ("Vir Mem", "虚拟内存"),
        "col.threads": ("Threads", "线程"),
        "col.command": ("Command", "命令"),
        
        // Status
        "loading": ("Loading processes...", "正在加载进程..."),
        "refreshing": ("Refreshing...", "正在刷新..."),
        "noProcesses": ("No processes found", "未找到进程"),
        "adjustSearch": ("Try adjusting your search", "请调整搜索条件"),
        "selected": ("Selected", "已选择"),
        "copied": ("Copied!", "已复制!"),
        
        // Menu
        "language": ("Language", "语言"),
        "copyName": ("Copy Process Name", "复制进程名称"),
        "copyCommand": ("Copy Process Command", "复制进程命令"),
        "copyAllInfo": ("Copy All Information", "复制所有信息"),
        "searchOnline": ("Search Online", "在线查询"),
        "expand": ("Expand", "展开"),
        "collapse": ("Collapse", "折叠"),
        "expandChildren": ("Expand All Children", "展开所有子项"),
        "collapseChildren": ("Collapse All Children", "折叠所有子项"),
        
        // Copy description labels
        "desc.pid": ("PID", "进程 ID"),
        "desc.name": ("Name", "名称"),
        "desc.user": ("User", "用户"),
        "desc.cpu": ("CPU", "CPU"),
        "desc.resMem": ("Resident Memory", "常驻内存"),
        "desc.virMem": ("Virtual Memory", "虚拟内存"),
        "desc.threads": ("Threads", "线程数"),
        "desc.prio": ("Priority/Nice", "优先级/Nice"),
        "desc.command": ("Command", "命令"),
        
        // About dialog
        "about.version": ("Version", "版本"),
        "about.description": ("A macOS process monitor with hierarchical tree view.", "支持层级树状视图的 macOS 进程监控工具。"),
        "about.author": ("Author", "作者"),
        "about.license": ("License", "许可证"),
        "about.visitWebsite": ("Visit Website", "访问网站"),
        "about.close": ("Close", "关闭"),
        
        // Network connections
        "col.connections": ("Conns", "连接"),
        "viewNetworkConnections": ("View Network Connections", "查看网络连接"),
        "net.title": ("Network Connections", "网络连接"),
        "net.connections": ("connections", "个连接"),
        "net.col.proto": ("Proto", "协议"),
        "net.col.family": ("Family", "类型"),
        "net.col.localAddr": ("Local Addr", "本地地址"),
        "net.col.localPort": ("L-Port", "本地端口"),
        "net.col.remoteAddr": ("Remote Addr", "远程地址"),
        "net.col.remotePort": ("R-Port", "远程端口"),
        "net.col.state": ("State", "状态"),
        "net.noConnections": ("No network connections", "无网络连接"),
        "net.close": ("Close", "关闭"),
    ]
    
    /// Get localized string for key
    static func s(_ key: String) -> String {
        guard let pair = strings[key] else { return key }
        return isChinese ? pair.zh : pair.en
    }
}
