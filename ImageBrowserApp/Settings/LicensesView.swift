import SwiftUI

/// Third-party software notices. LAME is LGPL: the notice, the license
/// text and where to get the source have to be reachable in the app.
struct LicensesView: View {
    var body: some View {
        List {
            Section {
                Text("MP3への書き出しに LAME 3.100 を使用しています。LAME は GNU Lesser General Public License (LGPL) バージョン2 以降のもとで配布されています。")
                    .font(.footnote)
                Link("LAME のソースコード", destination: URL(string: "https://lame.sourceforge.io/")!)
                Link("GNU LGPL の全文", destination: URL(string: "https://www.gnu.org/licenses/old-licenses/lgpl-2.0.html")!)
                Text("アプリに組み込んだ LAME を差し替えるためのファイルが必要な場合は、サポートページからお問い合わせください。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } header: {
                Text("LAME")
            }
            Section {
                Text("SVG画像の保存に SwiftDraw を使用しています(zlib License)。")
                    .font(.footnote)
                Link("SwiftDraw", destination: URL(string: "https://github.com/swhitty/SwiftDraw")!)
            } header: {
                Text("SwiftDraw")
            }
            Section {
                Text("広告の表示に Google Mobile Ads SDK、利用状況の集計に Firebase を使用しています。")
                    .font(.footnote)
                Link("Google Mobile Ads SDK の利用規約", destination: URL(string: "https://developers.google.com/admob/terms")!)
                Link("Firebase の利用規約", destination: URL(string: "https://firebase.google.com/terms")!)
            } header: {
                Text("Google")
            }
        }
        .navigationTitle("ライセンス")
        .navigationBarTitleDisplayMode(.inline)
    }
}
