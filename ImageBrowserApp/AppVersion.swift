import Foundation

enum AppVersion {
    /// e.g. "v0.1.0 (3)" — the build number is what changes between test installs,
    /// so it is the quickest way to confirm which binary is actually running.
    /// For internal use only (logs, diagnostics) -- a build number means
    /// nothing to a regular user. `displayShort` below is what any screen a
    /// user actually looks at should show instead.
    static var short: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "v\(version) (\(build))"
    }

    /// Marketing version only, no build number -- for any UI a user actually
    /// sees. The build number stays available via `short` for logs.
    static var displayShort: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        return "v\(version)"
    }
}
