import Foundation

enum SearchEngine: String, CaseIterable, Identifiable {
    case google
    case yahoo
    case bing

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .google: return "Google"
        case .yahoo: return "Yahoo!"
        case .bing: return "Bing"
        }
    }

    var homeURL: URL {
        switch self {
        case .google: return URL(string: "https://www.google.com")!
        case .yahoo: return URL(string: "https://www.yahoo.co.jp")!
        case .bing: return URL(string: "https://www.bing.com")!
        }
    }

    func searchURL(for query: String) -> URL {
        var components: URLComponents
        switch self {
        case .google:
            components = URLComponents(string: "https://www.google.com/search")!
            components.queryItems = [URLQueryItem(name: "q", value: query)]
        case .yahoo:
            components = URLComponents(string: "https://search.yahoo.co.jp/search")!
            components.queryItems = [URLQueryItem(name: "p", value: query)]
        case .bing:
            components = URLComponents(string: "https://www.bing.com/search")!
            components.queryItems = [URLQueryItem(name: "q", value: query)]
        }
        return components.url!
    }
}

/// Backed by UserDefaults directly (not just @AppStorage) so non-View code
/// like WebViewController/BrowserDefaults can read the current choice too.
enum SearchEngineStore {
    static let key = "searchEngine"

    static var current: SearchEngine {
        get {
            UserDefaults.standard.string(forKey: key).flatMap(SearchEngine.init) ?? .google
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: key)
        }
    }
}
