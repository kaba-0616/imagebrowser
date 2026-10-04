import UIKit

/// The Google Form for reporting sites where extraction/long-press saving
/// doesn't work. The page URL, app version and device are pre-filled so the
/// reporter only has to pick what went wrong.
enum ReportForm {
    private static let base = "https://docs.google.com/forms/d/e/1FAIpQLSflFGd8_t_w1Vw0Q0JvPL3nB8oBXlS2QGUCLhLuQCUJEQL9Pw/viewform"

    // Field ids, read from the form's published page (FB_PUBLIC_LOAD_DATA_).
    // They change if a question is deleted and re-created in the form.
    private static let pageURLField = "entry.1600436185"
    private static let versionField = "entry.1679109138"
    private static let deviceField = "entry.469008126"

    static func url(pageURL: URL? = nil) -> URL {
        var components = URLComponents(string: base)!
        var items = [
            URLQueryItem(name: "usp", value: "pp_url"),
            // Build number included: reports are for the developer, who
            // needs to know exactly which binary it was.
            URLQueryItem(name: versionField, value: AppVersion.short),
            URLQueryItem(name: deviceField, value: deviceDescription),
        ]
        if let pageURL, pageURL.scheme == "http" || pageURL.scheme == "https" {
            items.append(URLQueryItem(name: pageURLField, value: pageURL.absoluteString))
        }
        components.queryItems = items
        return components.url!
    }

    /// e.g. "iPhone17,1 / iOS 26.0" -- the model identifier, since
    /// UIDevice.model only ever says "iPhone".
    private static var deviceDescription: String {
        var info = utsname()
        uname(&info)
        let machine = withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        return "\(machine) / iOS \(UIDevice.current.systemVersion)"
    }
}
