import SwiftUI

struct SettingsView: View {
    @ObservedObject var store: StoreManager
    let onClose: () -> Void

    @AppStorage(SearchEngineStore.key) private var searchEngineRaw = SearchEngine.google.rawValue
    @State private var isRestoring = false
    @State private var restoreMessage: String?
    @State private var showSaveLog = false
    @State private var adBlockEnabled = AdBlockStore.isEnabled
    @State private var verboseDiagnostics = DiagnosticsStore.isVerbose
    @State private var usageStatsEnabled = UsageStats.isEnabled
    @AppStorage(SaveDestination.key) private var saveDestinationRaw = SaveDestination.photos.rawValue
    @AppStorage(AudioOutputFormat.key) private var audioFormatRaw = AudioOutputFormat.mp3.rawValue

    var body: some View {
        NavigationView {
            Form {
                Section("検索エンジン") {
                    Picker("デフォルト検索エンジン", selection: $searchEngineRaw) {
                        ForEach(SearchEngine.allCases) { engine in
                            Text(engine.displayName).tag(engine.rawValue)
                        }
                    }
                }

                Section("広告ブロック") {
                    Toggle("ページ内の広告をブロック", isOn: Binding(
                        get: { adBlockEnabled },
                        set: {
                            adBlockEnabled = $0
                            AdBlockStore.isEnabled = $0
                        }
                    ))
                }

                Section {
                    Picker("保存先", selection: $saveDestinationRaw) {
                        ForEach(SaveDestination.allCases) { Text($0.label).tag($0.rawValue) }
                    }
                    Picker("音声の形式", selection: $audioFormatRaw) {
                        ForEach(AudioOutputFormat.allCases) { Text($0.label).tag($0.rawValue) }
                    }
                } header: {
                    Text("動画・音声の保存")
                } footer: {
                    Text("保存するたびに変えられます。ここでは最初に選ばれている値を決めます。")
                }

                Section("Pro") {
                    HStack {
                        Text("現在のプラン")
                        Spacer()
                        Text(planName)
                            .foregroundColor(.secondary)
                    }
                    NavigationLink("プランを見る") {
                        PlanListView(store: store)
                    }
                    Button {
                        Task {
                            isRestoring = true
                            await store.restorePurchases()
                            isRestoring = false
                            restoreMessage = store.hasPurchasedPro ? "Proが復元されました" : "復元できる購入が見つかりませんでした"
                        }
                    } label: {
                        if isRestoring {
                            ProgressView()
                        } else {
                            Text("購入を復元")
                        }
                    }
                    .disabled(isRestoring)
                    if let restoreMessage {
                        Text(restoreMessage)
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                }

                // TestFlight/simulator builds only -- never shown on App Store installs.
                if StoreManager.isTestBuild {
                    Section {
                        Toggle("Proを一時的に無効にする", isOn: $store.ignoreProForTesting)
                    } header: {
                        Text(StoreManager.isSimulator ? "テスト用(シミュレータ)" : "テスト用(TestFlight版のみ)")
                    } footer: {
                        Text("無料ユーザーの動作(広告・リワード広告など)を確認するための設定です。購入は取り消されません。")
                    }
                }

                Section {
                    Toggle("利用状況を送信する", isOn: Binding(
                        get: { usageStatsEnabled },
                        set: {
                            usageStatsEnabled = $0
                            UsageStats.isEnabled = $0
                        }
                    ))
                } header: {
                    Text("改善へのご協力")
                } footer: {
                    Text("画像・動画の抽出・保存を行ったサイトのドメイン(例: sakurazaka46.com)と件数、購入の有無を送信し、対応サイトの改善に使います。ページのURL・画像・入力内容は送信しません。")
                }

                Section("サポート") {
                    Link("プライバシーポリシー", destination: URL(string: "https://nova-droplet-464.notion.site/ImageBrowser-3e5296d4576e8167ba4ff8b30c4f8b99")!)
                    Link("サポート", destination: URL(string: "https://nova-droplet-464.notion.site/ImageBrowser-3e5296d4576e815cb39acc3d6bc37793")!)
                    NavigationLink("ライセンス") { LicensesView() }
                    NavigationLink("お問い合わせ") { ContactView() }
                }

                // Developer-only: TestFlight/simulator builds (AppVersion.isTestBuild).
                if AppVersion.isTestBuild {
                    Section {
                        Button("ログ") { showSaveLog = true }
                        Toggle("詳細ログを記録", isOn: Binding(
                            get: { verboseDiagnostics },
                            set: {
                                verboseDiagnostics = $0
                                DiagnosticsStore.isVerbose = $0
                            }
                        ))
                    } header: {
                        Text("開発用(TestFlight版のみ)")
                    } footer: {
                        Text("不具合の調査用です。オンにすると、ページの通信の概要などもログに記録されます。")
                    }
                }

                Section {
                    HStack {
                        Text("バージョン")
                        Spacer()
                        Text(AppVersion.displayShort)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .navigationTitle("設定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("閉じる") { onClose() }
                }
            }
            .sheet(isPresented: $showSaveLog) {
                SaveLogView { showSaveLog = false }
            }
        }
        .navigationViewStyle(.stack)
    }

    private var planName: String {
        guard store.hasPurchasedPro else { return "無料" }
        return ProProduct(rawValue: store.activeProductID ?? "")?.includesMedia == true ? "Pro+" : "Pro"
    }
}
