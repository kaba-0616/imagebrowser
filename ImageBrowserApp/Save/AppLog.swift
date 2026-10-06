import Foundation

/// Unified, persistent, timestamped log across the whole app -- page loads,
/// long-press hit-tests, bulk extraction, and saves -- not just saves.
/// Survives the app being backgrounded/killed mid-operation, so "保存が
/// 出てこなかった" reports have something to correlate against (was the
/// page even loaded? did extraction find anything? did the save itself
/// fail?). No debugger is attached to a TestFlight install, so this is the
/// only record of what actually happened.
enum AppLog {
    private static let key = "appLog"
    /// Capped so a long browsing session doesn't grow this without bound --
    /// UserDefaults isn't meant to hold megabytes of text.
    private static let maxEntries = 400

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    static func log(_ text: String, isError: Bool = false) {
        var lines = UserDefaults.standard.stringArray(forKey: key) ?? []
        let stamp = formatter.string(from: Date())
        lines.append("\(stamp) \(isError ? "[ERR] " : "")\(text)")
        if lines.count > maxEntries {
            lines.removeFirst(lines.count - maxEntries)
        }
        UserDefaults.standard.set(lines, forKey: key)
    }

    /// Detailed diagnostics (every network response, storage scans, hit-test
    /// trails, ...) -- recorded only while 設定 > 詳細ログ is on. Without the
    /// switch these drowned out everything else: one page load produced
    /// ~50 lines, and with a 400-line cap the useful lines (saves, errors)
    /// scrolled away within a couple of extractions.
    static func debug(_ text: String) {
        guard DiagnosticsStore.isVerbose else { return }
        log(text)
    }

    static func read() -> [String] {
        UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}

/// 設定 > 詳細ログ. Off by default -- it's for investigating a specific
/// site's behavior, not for everyday use.
enum DiagnosticsStore {
    static let key = "verboseDiagnostics"

    static var isVerbose: Bool {
        // Off on App Store installs even if switched on in 1.2.0, when the
        // switch was still offered there; it now only exists in test builds.
        get { AppVersion.isTestBuild && UserDefaults.standard.bool(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}
