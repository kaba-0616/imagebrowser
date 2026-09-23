import SwiftUI

@main
struct ImageBrowserApp: App {
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        // Logged mainly for diagnosing tab-state bugs: background/foreground
        // transitions are exactly when races around WKWebView's async state
        // (see TabManager.saveState) are most likely to bite.
        .onChange(of: scenePhase) { newPhase in
            AppLog.log("アプリの状態変化: \(newPhase.logLabel)")
        }
    }
}

private extension ScenePhase {
    var logLabel: String {
        switch self {
        case .active: return "active(フォアグラウンド)"
        case .inactive: return "inactive(遷移中)"
        case .background: return "background(バックグラウンド)"
        @unknown default: return "unknown"
        }
    }
}
