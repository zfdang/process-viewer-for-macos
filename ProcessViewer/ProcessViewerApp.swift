import SwiftUI

@main
struct ProcessViewerApp: App {
    @Environment(\.openWindow) private var openWindow
    @StateObject private var localization = L.shared
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(localization)
        }
        .defaultSize(width: 1200, height: 700)
        .windowStyle(.automatic)
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandGroup(replacing: .appInfo) {
                Button("About Process Viewer") {
                    openWindow(id: "about")
                }
            }
            
            // Language menu
            CommandGroup(after: .toolbar) {
                Menu(L.s("language")) {
                    ForEach(AppLanguage.allCases) { lang in
                        Button(lang.displayName) {
                            localization.preference = lang
                        }
                        .disabled(localization.preference == lang)
                    }
                }
            }
        }
        
        // Custom About window
        Window("About Process Viewer", id: "about") {
            AboutView()
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }
}

/// Custom About view with buttons
struct AboutView: View {
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        VStack(spacing: 16) {
            // App icon
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 80, height: 80)
            
            // App name and version (name stays English per user request)
            Text("Process Viewer")
                .font(.title.bold())
            
            Text("\(L.s("about.version")) 1.0.0")
                .font(.callout)
                .foregroundColor(.secondary)
            
            // Description
            Text(L.s("about.description"))
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 20)
            
            Divider()
                .padding(.horizontal, 40)
            
            // Author info
            VStack(spacing: 6) {
                HStack {
                    Text("\(L.s("about.author")):")
                        .fontWeight(.medium)
                    Text("zfdang")
                }
                .font(.callout)
                
                HStack {
                    Text("\(L.s("about.license")):")
                        .fontWeight(.medium)
                    Text("MIT")
                }
                .font(.callout)
            }
            .foregroundColor(.secondary)
            
            Spacer()
                .frame(height: 8)
            
            // Buttons
            HStack(spacing: 16) {
                Button(L.s("about.visitWebsite")) {
                    if let url = URL(string: "https://proc.zfdang.com") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.bordered)
                
                Button(L.s("about.close")) {
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 380, height: 360)
    }
}
