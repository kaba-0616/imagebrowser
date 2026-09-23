import Foundation

/// Survives the app being backgrounded/killed mid-save, so "保存が出て
/// こなかった" reports have something to inspect on the next launch --
/// no debugger is attached to a TestFlight install, so this is the only
/// record of what actually happened.
enum PersistentLog {
    private static let key = "lastSaveLog"

    static func write(_ entries: [PhotoSaver.LogEntry]) {
        let lines = entries.map { entry in
            (entry.isError ? "[ERR] " : "") + entry.text
        }
        UserDefaults.standard.set(lines, forKey: key)
    }

    static func read() -> [String] {
        UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}
