import SwiftUI
import UIKit
import WebKit

/// Settings > お問い合わせ (same design as ImageKeeper's). Opens the Google
/// Form with the inquiry number, device model, iOS version and app version
/// already filled in, and keeps the
/// numbers of submitted inquiries on screen afterwards -- the form's own
/// confirmation page cannot show the number, and a screenshot mailed
/// separately has to be matched to its form response by it.
struct ContactView: View {
    @ObservedObject private var store = ContactStore.shared
    @Environment(\.openURL) private var openURL
    @State private var showingForm = false
    @State private var copiedID: String?

    var body: some View {
        List {
            Section {
                Button {
                    store.prepareInquiry()
                    showingForm = true
                } label: {
                    Label("お問い合わせフォームを開く", systemImage: "envelope")
                }
            } footer: {
                Text("機種名・iOSのバージョン・アプリのバージョン・問い合わせ番号は自動で入力されます。")
            }

            if !store.submitted.isEmpty {
                Section {
                    ForEach(store.submitted) { inquiry in
                        submittedRow(inquiry)
                    }
                } header: {
                    Text("送信済みのお問い合わせ")
                } footer: {
                    Text("スクリーンショットなどがある場合は、件名に問い合わせ番号を入れて \(ContactStore.supportAddress) までお送りください。番号をタップするとコピーできます。")
                }
            }
        }
        .navigationTitle("お問い合わせ")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingForm) {
            if let url = store.formURL() {
                ContactFormSheet(url: url) {
                    store.markSubmitted()
                } onClose: {
                    showingForm = false
                }
            }
        }
    }

    private func submittedRow(_ inquiry: ContactStore.Inquiry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                UIPasteboard.general.string = inquiry.id
                copiedID = inquiry.id
                Task {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    if copiedID == inquiry.id { copiedID = nil }
                }
            } label: {
                HStack {
                    Text(inquiry.id)
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(.primary)
                    Spacer()
                    Text(copiedID == inquiry.id ? "コピーしました" : ContactStore.dateText(inquiry.submittedAt))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            Button {
                if let url = ContactStore.mailURL(for: inquiry.id) { openURL(url) }
            } label: {
                Label("スクリーンショットをメールで送る", systemImage: "paperclip")
                    .font(.subheadline)
            }
        }
        .padding(.vertical, 4)
    }
}

/// The form in an in-app web view rather than Safari: only here can the app
/// see the page move to Google's `formResponse` URL, which is how it tells a
/// real submission from the user just closing the form.
struct ContactFormSheet: View {
    let url: URL
    let onSubmitted: () -> Void
    let onClose: () -> Void

    var body: some View {
        NavigationView {
            ContactFormWebView(url: url, onSubmitted: onSubmitted)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle("お問い合わせ")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("閉じる", action: onClose)
                    }
                }
        }
    }
}

private struct ContactFormWebView: UIViewRepresentable {
    let url: URL
    let onSubmitted: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onSubmitted: onSubmitted) }

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.navigationDelegate = context.coordinator
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        let onSubmitted: () -> Void
        private var reported = false

        init(onSubmitted: @escaping () -> Void) { self.onSubmitted = onSubmitted }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard !reported, webView.url?.path.hasSuffix("/formResponse") == true else { return }
            reported = true
            onSubmitted()
        }
    }
}

/// The inquiry number and the record of submitted inquiries. A number is
/// issued once and reused until the form is actually submitted, so opening
/// and closing the form does not leave a trail of numbers nobody sent.
final class ContactStore: ObservableObject {
    static let shared = ContactStore()

    static let supportAddress = "app.kaba.support@gmail.com"
    private static let formBase = "https://docs.google.com/forms/d/e/1FAIpQLSflFGd8_t_w1Vw0Q0JvPL3nB8oBXlS2QGUCLhLuQCUJEQL9Pw/viewform"
    // Field ids, read from the form's published page (FB_PUBLIC_LOAD_DATA_).
    // They change if a question is deleted and re-created in the form.
    private enum Entry {
        static let inquiryID = "entry.658267262"
        static let model = "entry.469008126"
        static let iOSVersion = "entry.1855921250"
        static let appVersion = "entry.1679109138"
        static let pageURL = "entry.1600436185"
    }
    private static let pendingKey = "contact.pendingInquiryID"
    private static let submittedKey = "contact.submittedInquiries"
    private static let keepCount = 5

    struct Inquiry: Codable, Identifiable {
        let id: String
        let submittedAt: Date
    }

    @Published private(set) var submitted: [Inquiry] = []
    private(set) var pendingID: String?

    private init() {
        let defaults = UserDefaults.standard
        pendingID = defaults.string(forKey: Self.pendingKey)
        if let data = defaults.data(forKey: Self.submittedKey),
           let list = try? JSONDecoder().decode([Inquiry].self, from: data) {
            submitted = list
        }
    }

    func prepareInquiry() {
        guard pendingID == nil else { return }
        let id = Self.newID()
        pendingID = id
        UserDefaults.standard.set(id, forKey: Self.pendingKey)
    }

    func markSubmitted() {
        guard let id = pendingID else { return }
        submitted.insert(Inquiry(id: id, submittedAt: Date()), at: 0)
        submitted = Array(submitted.prefix(Self.keepCount))
        pendingID = nil
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: Self.pendingKey)
        if let data = try? JSONEncoder().encode(submitted) {
            defaults.set(data, forKey: Self.submittedKey)
        }
    }

    /// `pageURL`: the page the results screen's "このサイトを報告" came from.
    func formURL(pageURL: URL? = nil) -> URL? {
        guard let id = pendingID, var components = URLComponents(string: Self.formBase) else { return nil }
        var items = [
            URLQueryItem(name: "usp", value: "pp_url"),
            URLQueryItem(name: Entry.inquiryID, value: id),
            URLQueryItem(name: Entry.model, value: Self.modelIdentifier()),
            URLQueryItem(name: Entry.iOSVersion, value: UIDevice.current.systemVersion),
            URLQueryItem(name: Entry.appVersion, value: AppVersion.short),
        ]
        if let pageURL, pageURL.scheme == "http" || pageURL.scheme == "https" {
            items.append(URLQueryItem(name: Entry.pageURL, value: pageURL.absoluteString))
        }
        components.queryItems = items
        return components.url
    }

    static func mailURL(for id: String) -> URL? {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = supportAddress
        components.queryItems = [URLQueryItem(name: "subject", value: "[\(id)] スクリーンショット")]
        return components.url
    }

    static func dateText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "M/d HH:mm"
        return formatter.string(from: date)
    }

    /// "IB-261005-7KQ3": app, date, then four characters from an alphabet
    /// without look-alikes (no 0/O, 1/I/L) so it survives being copied by hand.
    private static func newID() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyMMdd"
        let alphabet = Array("ABCDEFGHJKMNPQRSTUVWXYZ23456789")
        let suffix = String((0..<4).map { _ in alphabet.randomElement()! })
        return "IB-\(formatter.string(from: Date()))-\(suffix)"
    }

    /// e.g. "iPhone17,1". On the simulator `uname` reports the Mac's CPU, so
    /// the simulated device's identifier comes from the environment instead.
    private static func modelIdentifier() -> String {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            return simulated
        }
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }
}
