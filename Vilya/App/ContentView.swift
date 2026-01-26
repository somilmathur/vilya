import SwiftUI

struct ContentView: View {
    @Environment(AppState.self) var appState

    var body: some View {
        Group {
            if appState.isConnected {
                MainTabView()
            } else {
                ConnectionView()
            }
        }
    }
}

struct MainTabView: View {
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            SessionListView()
                .tabItem {
                    Label("Terminals", systemImage: "terminal")
                }
                .tag(0)

            FileBrowserView()
                .tabItem {
                    Label("Files", systemImage: "folder")
                }
                .tag(1)

            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gear")
                }
                .tag(2)
        }
    }
}

#Preview {
    ContentView()
        .environment(AppState())
}
