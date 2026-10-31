// 画像収集ロジック。ImageSaver(Safari Action Extension)のAction.jsから
// 収集アルゴリズム(img/picture/source/poster/CSS背景画像/OGP/SVG/
// lazy-load属性/リサイズURL復元)と、ページの仕分け(おすすめ記事・
// 部品・別記事の画像を既定で隠す、ソース走査、ギャラリーの原寸の
// 取得先)を移植したもの(仕分けは2026-10-31に追加)。
//
// window.__ImageBrowserCollector として以下を公開する:
//   collect(withBackgrounds) -> Array<{url, width, height, origin, excluded?, why?, page?, rendered?}>
//   collectAsync(...)        -> Instagramの投稿ではカルーセルを送ってから collect
//   collectNote()/walkNote() -> 直前の抽出の仕分け・送りの記録(ログ用)
//   findImageAt(x, y)        -> 座標上の画像URL(文字列)、無ければnull
(function () {
    "use strict";

    // インターフェース部品(スピナー・再生ボタン等)の静的リソースパス。
    // img_protect.pngはmdpr.jp(モデルプレス)の写真詳細ページで、本物の
    // サムネイルの真上に重なる保護用オーバーレイ画像。実在するsrcを持つ
    // ため素通りせず、長押しでこれを検出してしまうと本物の写真まで
    // 辿り着けない(elementsFromPointのスタックで先に見つかるため)。
    // splash/img/ はFlutter Web標準テンプレートの起動スプラッシュ画像
    // (light-3x.png等)の定位置。櫻坂46メッセージ(Flutter製アプリ)で、
    // ページ内で唯一実在するimg要素がこれだったため、長押しのたびに
    // これだけが検出されてしまっていた。除外することで、Canvas描画への
    // フォールバック(下のisFlutterPage/isCanvasRenderedPage参照)に
    // ちゃんと繋がるようにする。
    var UI_ASSET_PATH = /\/rsrc\.php\/|static\.cdninstagram\.com|\/static\.xx\.fbcdn\.net\/|\/img_protect\.png|\/splash\/img\/|\/ads?_img\//i;

    // .../<hash>/1200_1200_102400.jpg のようなリサイズ配信URLから
    // 元画像URLを復元する。
    var RESIZED_PATH = /^(.*\/[0-9a-f]{16,})\/\d+_\d+_\d+(\.(?:jpe?g|png|gif))$/i;
    var REQUESTED_BOX = /\/(\d+)_\d+_\d+\.[a-z]+$/i;

    // --- 原寸URLの復元(ImageSaverのAction.jsから移植、2026-10-31) -----
    // 各方式の実測値と経緯はImageSaver側のコメントにある。

    // WordPressは生成した各サイズを name-1024x683.jpg として元ファイルの
    // 隣に書く。/wp-content/uploads/ に限る。
    var WP_UPLOADS = /\/wp-content\/uploads\//i;
    var WP_SIZE_SUFFIX = /-\d{2,5}x\d{2,5}(\.(?:jpe?g|png|gif|webp))$/i;
    var WP_REQUESTED_WIDTH = /-(\d{2,5})x\d{2,5}\.[a-z]+$/i;
    var IMAGE_FILE_PATH = /\.(?:jpe?g|png|gif|webp|avif)$/i;

    // Akamai Image Manager(ogre.natalie.mu)。原本より大きい幅を要求すると
    // 原寸が返る。imwidth / impolicy はAkamai固有の名前で、ありふれた
    // width単独では反応しない。
    var AKAMAI_PARAMS = ["impolicy", "imwidth", "imdensity", "width", "height"];
    var AKAMAI_MAX_WIDTH = 4000;

    function akamaiOriginal(parsed) {
        if (!parsed.searchParams.has("imwidth")
            && !parsed.searchParams.has("impolicy")) { return null; }
        var full = new URL(parsed.href);
        for (var i = 0; i < AKAMAI_PARAMS.length; i++) {
            full.searchParams.delete(AKAMAI_PARAMS[i]);
        }
        full.searchParams.set("imwidth", String(AKAMAI_MAX_WIDTH));
        full.searchParams.set("imdensity", "1");
        return full.href;
    }

    // microCMS / imgix 系。クエリを全部外すと保管されている原本が返る
    // (zozoで 902px webp → 5499px JPEG)。fm(format)とw/hが揃うときだけ。
    var IMAGE_CDN_HOST = /(?:^|\.)microcms-assets\.io$|(?:^|\.)imgix\.net$/i;

    function formatQueryOriginal(parsed) {
        var q = parsed.searchParams;
        var looksLikeCDN = IMAGE_CDN_HOST.test(parsed.hostname)
            || (q.has("fm") && (q.has("w") || q.has("h")));
        if (!looksLikeCDN) { return null; }
        if (!IMAGE_FILE_PATH.test(parsed.pathname)) { return null; }
        var full = new URL(parsed.href);
        full.search = "";
        return full.href;
    }

    // Next.jsの画像最適化エンドポイント。urlパラメータが元画像そのもの。
    var NEXT_IMAGE_PATH = /\/_next\/image\/?$/i;

    function nextImageOriginal(parsed) {
        if (!NEXT_IMAGE_PATH.test(parsed.pathname)) { return null; }
        var src = parsed.searchParams.get("url");
        if (!src) { return null; }
        var full;
        try { full = new URL(src, parsed.href); } catch (e) { return null; }
        if (full.protocol !== "http:" && full.protocol !== "https:") { return null; }
        return full.href;
    }

    // Paperclip / CarrierWave系。番号3段の下のサイズ名フォルダを original に
    // (cocreco.kodansha.co.jp で large 1280px → original 1600px)。
    var SIZED_STYLE_PATH =
        /^(.*\/\d{3,}\/\d{3,}\/\d{3,}\/)(?:thumb|small|medium|large|xlarge|big)(\/[^\/]+)$/i;

    function sizedStyleOriginal(parsed) {
        if (!SIZED_STYLE_PATH.test(parsed.pathname)) { return null; }
        var full = new URL(parsed.href);
        full.pathname = parsed.pathname.replace(SIZED_STYLE_PATH, "$1original$2");
        return full.href;
    }

    // モデルプレス(img-mdpr.freetls.fastly.net)で確認したクエリ型の
    // リサイズ指定。ドメインごとにキー名が違うため、確認できたホストだけの
    // ホワイトリスト(未確認のサイトへ汎用的にクエリ除去をかけると、
    // 認証・署名用のクエリまで壊しかねない)。ogre.natalie.mu は上の
    // Akamai方式が先に効き、impolicy/imwidthの無いURLだけがここに来る。
    var QUERY_RESIZE_HOSTS = {
        "img-mdpr.freetls.fastly.net": ["width", "height", "crop", "quality", "enable", "auto"],
        "ogre.natalie.mu": ["impolicy", "width", "height"]
    };

    function originalOfQuery(parsed) {
        var keys = QUERY_RESIZE_HOSTS[parsed.hostname];
        if (!keys || !parsed.search) { return null; }
        var full = new URL(parsed.href);
        var changed = false;
        for (var i = 0; i < keys.length; i++) {
            if (full.searchParams.has(keys[i])) {
                full.searchParams.delete(keys[i]);
                changed = true;
            }
        }
        return changed ? full.href : null;
    }

    var LAZY_ATTRS = [
        "data-src", "data-original", "data-lazy-src", "data-lazy",
        "data-image", "data-url", "data-hi-res-src", "data-large-file",
        // realsound.jp(lozadライブラリ)で確認した、背景画像を遅延指定する属性。
        "data-background-image"
    ];

    // これより小さい箱に描かれたCSS背景画像はスプライト/アイコンとみなす。
    var SPRITE_MIN_BOX = 60;

    /// 縮小版URLの裏にある原本、または縮小版でなければnull。
    function originalOf(parsed) {
        var full;
        if (RESIZED_PATH.test(parsed.pathname)) {
            full = new URL(parsed.href);
            full.pathname = parsed.pathname.replace(RESIZED_PATH, "$1$2");
            return full.href;
        }
        if (WP_UPLOADS.test(parsed.pathname) && WP_SIZE_SUFFIX.test(parsed.pathname)) {
            full = new URL(parsed.href);
            full.pathname = parsed.pathname.replace(WP_SIZE_SUFFIX, "$1");
            return full.href;
        }
        // 既に原寸を指しているURL(書き換えても同じ)は縮小版ではない。
        var byPathStyle = sizedStyleOriginal(parsed);
        if (byPathStyle && byPathStyle !== parsed.href) { return byPathStyle; }
        var byQuery = akamaiOriginal(parsed) || nextImageOriginal(parsed)
                      || formatQueryOriginal(parsed) || originalOfQuery(parsed);
        if (byQuery && byQuery !== parsed.href) { return byQuery; }
        return null;
    }

    /// 縮小版URLが要求している幅。同じ写真の複数のサムネイルのうち
    /// 大きい方を残すための順位づけにだけ使う。
    function requestedWidth(href) {
        var parsed;
        try { parsed = new URL(href); } catch (e) { return 0; }
        var m = REQUESTED_BOX.exec(parsed.pathname) || WP_REQUESTED_WIDTH.exec(parsed.pathname);
        if (m) { return parseInt(m[1], 10); }
        var q = parsed.searchParams;
        var n = parseInt(q.get("imwidth") || q.get("width") || q.get("w"), 10);
        return isFinite(n) && n > 0 ? n : 0;
    }

    function bestFromSrcset(srcset) {
        if (!srcset) { return null; }
        var best = null;
        var bestScore = -1;
        var parts = srcset.split(",");
        for (var i = 0; i < parts.length; i++) {
            var bits = parts[i].trim().split(/\s+/);
            var candidate = bits[0];
            if (!candidate) { continue; }
            var score = 1;
            if (bits[1]) {
                var n = parseFloat(bits[1]);
                if (!isNaN(n)) {
                    score = /x$/.test(bits[1]) ? n * 1000 : n;
                }
            }
            if (score > bestScore) {
                bestScore = score;
                best = candidate;
            }
        }
        return best;
    }

    function fromLazyAttrs(el) {
        for (var i = 0; i < LAZY_ATTRS.length; i++) {
            var v = el.getAttribute(LAZY_ATTRS[i]);
            if (v) { return v; }
        }
        return null;
    }

    function sameURL(a, b) {
        try {
            return new URL(String(a).trim(), document.baseURI).href
                === new URL(String(b).trim(), document.baseURI).href;
        } catch (e) {
            return String(a) === String(b);
        }
    }

    // Canvas描画アプリでの長押しスナップショット切り出し(findImageAtが
    // 何も見つけられなかった場合のフォールバック)用に、押された場所の
    // 「本来の表示範囲」を返す。Flutter Webはアクセシビリティ用に、実際の
    // 見た目とぴったり同じ位置・サイズの透明なDOM要素(flt-semantics-*)を
    // 重ねて配置しているので、これのgetBoundingClientRect()が使える。
    // 見つからなければnull(呼び出し側で無難な固定サイズにフォールバックする)。
    function findCanvasRegionAt(x, y) {
        var stack;
        try { stack = document.elementsFromPoint(x, y); } catch (e) { stack = []; }
        for (var i = 0; i < stack.length; i++) {
            var tag = (stack[i].tagName || "").toLowerCase();
            if (tag.indexOf("flt-semantics") !== 0) { continue; }
            var r = stack[i].getBoundingClientRect();
            if (r.width > 4 && r.height > 4) {
                return { x: r.left, y: r.top, width: r.width, height: r.height };
            }
        }
        return null;
    }

    // Flutter Webは画面をCanvasに直接描画するため、写真やアイコンは
    // 通常の<img>/CSS背景画像としてDOMに一切現れない(櫻坂46メッセージで
    // 確認)。<flutter-view>/<flt-glass-pane>はFlutterのWeb出力が必ず生成する
    // ルート要素なので、これの有無でCanvas描画アプリかどうかを判定する。
    function isFlutterPage() {
        return !!document.querySelector("flutter-view, flt-glass-pane");
    }

    // --- Instagram(ImageSaverのAction.jsから移植) ---------------------
    // 投稿は /p/<code>/ と /<ユーザー>/p/<code>/ の両方で開けるので、
    // ショートコードだけが投稿を特定する。
    var POST_PATH = /(?:^|\/)(?:p|reel|reels|tv)\/([^\/?#]+)/i;

    function isInstagram() {
        var host = (document.location.hostname || "").toLowerCase();
        return host === "instagram.com" || host.slice(-14) === ".instagram.com";
    }

    function onPostPermalink() {
        return POST_PATH.test(document.location.pathname);
    }

    function pageKey(pathname) {
        var post = POST_PATH.exec(String(pathname || ""));
        if (post) { return "post:" + post[1]; }
        var parts = String(pathname || "").split("/");
        var key = "path:";
        var kept = 0;
        for (var i = 0; i < parts.length && kept < 2; i++) {
            if (!parts[i]) { continue; }
            key += "/" + parts[i];
            kept++;
        }
        return key;
    }

    // 投稿ページで、別の投稿(下に並ぶ同じ人の他の投稿)やプロフィールへの
    // リンクに包まれた画像。URLもサイズも投稿の写真と同じCDN・同じ形式で
    // 区別できず、何に包まれているかでしか見分けられない。プロフィールや
    // フィードは全部が別の投稿へのリンクなので、投稿ページに限る。
    function linksElsewhere(el) {
        if (!isInstagram() || !onPostPermalink()) { return false; }
        var link;
        try { link = el.closest("a[href]"); } catch (e) { return false; }
        if (!link || !link.href) { return false; }
        var target;
        try { target = new URL(link.href, document.baseURI); } catch (e) { return false; }
        if (target.origin !== document.location.origin) { return true; }
        return pageKey(target.pathname) !== pageKey(document.location.pathname);
    }

    // プロフィール・フィードの一覧では、動画・リールのカバーは<video>の無い
    // 普通の<img>で、目印は近くの<svg aria-label="動画"/"リール動画">だけ
    // (ImageSaverで実際のマークアップを確認済み)。
    function instagramVideoCovers(root) {
        var covers = [];
        if (!isInstagram() || onPostPermalink()) { return covers; }
        var icons = root.querySelectorAll("[aria-label]");
        for (var i = 0; i < icons.length; i++) {
            var label = icons[i].getAttribute("aria-label") || "";
            if (!/video|reel|動画|リール|クリップ/i.test(label)) { continue; }
            var walk = icons[i].parentElement;
            var found = null;
            for (var steps = 0; steps < 6 && walk; steps++) {
                found = walk.querySelector("img");
                if (found) { break; }
                walk = walk.parentElement;
            }
            if (found && covers.indexOf(found) === -1) { covers.push(found); }
        }
        return covers;
    }

    // DOMを一切見ずに、ブラウザが実際に読み込んだ画像のURL一覧を
    // Resource Timing APIから拾う。Canvas描画アプリでは、写真データ自体は
    // 普通にHTTPで取得されて画面に描かれているので、DOM収集の穴を
    // この方法で埋められる(幅/高さの情報は無いため0のまま)。
    // 櫻坂46メッセージ(CloudFront配信)では、同じ写真が
    // /messages/files/(フルサイズ)と/messages/thumbnails/(縮小版)の
    // 2本立てになっている。タイムライン一覧で読み込まれるのは縮小版だけで、
    // フルサイズは写真を個別に開いたときにしか取得されない。そのためここで
    // 縮小版を除外すると、タイムラインの写真が一枚も拾えなくなる(実機で
    // 確認済み)。縮小版も返し、フルサイズが見つかっている写真の縮小版だけを
    // Swift側(WebViewController.dropThumbnailsWithFullSize)で外す。

    // 診断用: クリアする「前」に、通信履歴全体を拡張子別に集計しておく。
    // 画像が増えないとき、そもそも通信自体が起きていないのか、起きては
    // いるが画像扱いされていないのか(拡張子なし・data:等)を切り分ける。
    function resourceTimingBreakdown() {
        var byExt = {};
        try {
            var entries = performance.getEntriesByType("resource");
            for (var i = 0; i < entries.length; i++) {
                var m = /\.([a-z0-9]+)(?:\?|#|$)/i.exec(entries[i].name);
                var ext = m ? m[1].toLowerCase() : "(拡張子なし)";
                byExt[ext] = (byExt[ext] || 0) + 1;
            }
        } catch (e) {}
        return byExt;
    }

    // 以前はここで「見つけたURLを時刻つきで憶えて何分か経ったら間引く」を
    // JS側(ページ内)でやっていたが、バックグラウンド中にiOSがWKWebViewの
    // 裏側のプロセスをメモリ節約のために作り直すと、ページ内のJS状態ごと
    // 消えてしまい、逆に結果が先細りする不具合が実機で確認された。
    // 蓄積・間引きはWebViewController(アプリ本体側、ページの生き死にに
    // 影響されない)に移し、ここは「今読める通信履歴をそのまま返すだけ」の
    // 単純な関数に戻す。
    function resourceTimingImages() {
        var out = [];
        try {
            var entries = performance.getEntriesByType("resource");
            for (var i = 0; i < entries.length; i++) {
                var url = entries[i].name;
                if (!/\.(jpe?g|png|gif|webp)(\?|#|$)/i.test(url)) { continue; }
                // サイト自身のアイコンやメンバー/グループのアイコン、アプリ設定用
                // 画像も返す。Swift側(WebViewController.siteAssetReason)が
                // 「除外した画像」へ回す(以前はここで捨てていた)。
                out.push(url);
            }
            // Swift側(WebViewController)が結果を累積して憶えておくので、
            // ここで読み終えた分は消化してよい。消化しておかないと、
            // WebKitのバッファ上限(到達すると新しいエントリの記録自体が
            // 止まる)に、Flutterのフレームワーク本体の読み込みだけで
            // 達してしまい、その後スクロールで新たに読み込まれる写真が
            // 一切記録されなくなる。
            performance.clearResourceTimings();
        } catch (e) {}
        return out;
    }

    // --- ページの仕分け(ImageSaverのAction.jsから移植、2026-10-31) -----
    // 各判定の経緯(どのサイトで何件外れたか)はImageSaver側のコメントにある。
    // 判定は「捨てる」ではなく「既定で隠す」(excluded = "other" + why)。
    // 外れたらフィルターから戻せる。

    // 坂道グループの日記ページには、他メンバーの最新記事のサムネイルと
    // メンバー一覧のアイコンが並ぶ。
    var MEMBER_WIDGET_HOSTS = ["sakurazaka46.com", "hinatazaka46.com", "nogizaka46.com"];
    var DIARY_DETAIL_PATH = /\/diary\/detail\/\d+/i;
    var DIARY_SECTION_PATH = /\/diary\//i;
    var MEMBER_AVATAR_MAX_BOX = 300;

    function hostHasMemberWidget() {
        var host = String(document.location.hostname || "").toLowerCase();
        for (var i = 0; i < MEMBER_WIDGET_HOSTS.length; i++) {
            var h = MEMBER_WIDGET_HOSTS[i];
            if (host === h || host.slice(-(h.length + 1)) === "." + h) { return true; }
        }
        return false;
    }

    var MAIN_SIZED_RATIO = 0.9;
    var TINY_RENDERED_RATIO = 0.16;
    var ITEM_ID_SEGMENT = /^(?:\d+|[0-9a-z_-]*\d[0-9a-z_-]{7,})$/i;
    var YEAR_SEGMENT = /^(?:19|20)\d{2}$/;
    var RELATED_WORDS = [
        "related", "recommend", "recommended", "recommendation", "recommendations",
        "ranking", "popular", "pickup",
        "search", "parts", "menu", "sidebar", "global",
        "author", "writer", "byline", "profile", "avatar",
        "outbrain", "taboola", "popin",
        "more-article", "more-articles", "more-news",
        "other-article", "other-articles", "other-post", "other-posts"
    ];
    var ARTICLE_URL_ATTRS = ["data-url", "data-href", "data-permalink", "data-article-url"];
    var BANNER_FILENAME = /(?:^|[\/_-])(?:banner|bnr|logo|icon|ic|nav|btn|sprite|copy)s?(?:[\/_.-]|$)/i;
    var SITE_ASSET_FILE = /^\/(?:img|images|assets|static|common|shared)\/[^\/]+$/i;
    var WP_SITE_ASSET = /\/wp-content\/(?:themes|plugins)\//i;
    var GALLERY_MIN_PAGES = 3;
    var LEAD_AREA_MULTIPLE = 3;
    var LOADED_AREA_FLOOR = 64 * 64;

    function pathSegments(pathname) {
        var parts = String(pathname || "").split("/");
        var kept = [];
        for (var i = 0; i < parts.length; i++) {
            if (parts[i]) { kept.push(parts[i]); }
        }
        return kept;
    }

    /// 番号は3桁以上だけ記事IDとみなす(/2026/10/26/slug/ の「26」を除く)。
    function looksLikeItemId(seg) {
        if (!ITEM_ID_SEGMENT.test(seg) || YEAR_SEGMENT.test(seg)) { return false; }
        if (/^\d+$/.test(seg)) { return seg.length >= 3; }
        return true;
    }

    /// 記事そのものを指している階層(3段まで遡る)。無ければ null。
    function articleParentPath(pathname) {
        var kept = pathSegments(pathname);
        if (kept.length < 3) { return null; }
        kept.pop();
        for (var up = 0; up < 3 && kept.length >= 2; up++) {
            if (looksLikeItemId(kept[kept.length - 1])) {
                return "/" + kept.join("/");
            }
            kept.pop();
        }
        return null;
    }

    var lastCollectNote = "";

    function collect(withBackgrounds) {
        var seen = {};
        var images = [];
        var order = 0;
        var startedAt = Date.now();
        var notes = [];

        var here = String(document.location.pathname || "");
        var hereTrimmed = here.replace(/\/+$/, "");
        var thisPageKey = pageKey(here);
        var thisArticleParent = articleParentPath(here);
        var onDiaryDetail = hostHasMemberWidget() && DIARY_DETAIL_PATH.test(here);
        var onCarouselPost = isInstagram() && onPostPermalink();

        // 「大きい」「小さい」は画面幅に対する割合で決める(固定pxにすると
        // iPhoneでは主役の写真でも届かず判定ごと無効になる)。
        var viewportWidth = 0;
        try {
            viewportWidth = (document.documentElement && document.documentElement.clientWidth) || 0;
        } catch (e) { viewportWidth = 0; }
        if (!(viewportWidth > 0)) { viewportWidth = 390; }
        var MAIN_IMAGE_MIN_BOX = Math.max(280, viewportWidth * 0.5);

        var widestCache = null;
        function widestRendered() {
            if (widestCache !== null) { return widestCache; }
            widestCache = 0;
            var imgs;
            try { imgs = document.querySelectorAll("img"); } catch (e) { return 0; }
            for (var i = 0; i < imgs.length; i++) {
                var r;
                try { r = imgs[i].getBoundingClientRect(); } catch (e) { continue; }
                if (r && r.width > widestCache) { widestCache = r.width; }
            }
            return widestCache;
        }

        function pageHasMainImage() {
            return widestRendered() >= MAIN_IMAGE_MIN_BOX;
        }

        function isMainSized(el) {
            var widest = widestRendered();
            if (!(widest > 0)) { return false; }
            var rect;
            try { rect = el.getBoundingClientRect(); } catch (e) { return false; }
            if (!rect) { return false; }
            return rect.width >= MAIN_IMAGE_MIN_BOX && rect.width >= widest * MAIN_SIZED_RATIO;
        }

        function sameArticle(targetPathname) {
            var t = String(targetPathname || "").replace(/\/+$/, "");
            if (t === hereTrimmed) { return true; }
            if (t.indexOf(hereTrimmed + "/") === 0) { return true; }
            if (thisArticleParent) {
                return t === thisArticleParent || t.indexOf(thisArticleParent + "/") === 0;
            }
            return false;
        }

        function linkTarget(el) {
            var link;
            try { link = el.closest("a[href]"); } catch (e) { return null; }
            if (!link || !link.href) { return null; }
            try { return new URL(link.href, document.baseURI); } catch (e) { return null; }
        }

        /// Instagramの投稿ページと坂道の日記詳細ページだけ: 別の投稿・
        /// 別の日記へのリンクに包まれた画像。
        function linksElsewhereHere(el) {
            if (!onDiaryDetail && !onCarouselPost) { return false; }
            var target = linkTarget(el);
            if (!target) { return false; }
            if (target.origin !== document.location.origin) { return true; }
            if (onDiaryDetail) {
                return target.pathname.replace(/\/+$/, "") !== hereTrimmed;
            }
            return pageKey(target.pathname) !== thisPageKey;
        }

        /// 日記ページ下の「メンバー別ブログ」一覧のアイコン。リンク先では
        /// 区別できず、箱の大きさで見分ける。
        function isMemberAvatar(el) {
            if (!hostHasMemberWidget() || !DIARY_SECTION_PATH.test(here)) { return false; }
            var rect;
            try { rect = el.getBoundingClientRect(); } catch (e) { return false; }
            return rect.width <= MEMBER_AVATAR_MAX_BOX && rect.height <= MEMBER_AVATAR_MAX_BOX;
        }

        /// WordPressの「関連記事」タイル: 小さな生成サイズで、別ページへの
        /// リンクに包まれたもの。
        function isRelatedThumb(el, url) {
            var m = WP_REQUESTED_WIDTH.exec(String(url || "").split(/[?#]/)[0]);
            if (!m || parseInt(m[1], 10) > 300 || !WP_UPLOADS.test(String(url))) { return false; }
            var target = linkTarget(el);
            if (!target) { return false; }
            if (IMAGE_FILE_PATH.test(target.pathname)) { return false; }
            return target.origin !== document.location.origin
                || target.pathname.replace(/\/+$/, "") !== hereTrimmed;
        }

        /// 主役の写真があるページで、別の記事へのリンクに包まれたサムネイル。
        function isOtherPostThumb(el) {
            if (!pageHasMainImage()) { return false; }
            if (isMainSized(el)) { return false; }
            var target = linkTarget(el);
            if (!target) { return false; }
            if (IMAGE_FILE_PATH.test(target.pathname)) { return false; }
            if (target.origin !== document.location.origin) { return true; }
            return !sameArticle(target.pathname);
        }

        // 見ているURLに含まれる語は、そのサイトでは「記事の種別」なので外す
        // (s-style.machico.mu の /pickup/ で本文が丸ごと消えた)。
        var RELATED_SECTION = (function () {
            var lower = here.toLowerCase();
            var words = [];
            for (var i = 0; i < RELATED_WORDS.length; i++) {
                if (lower.indexOf(RELATED_WORDS[i]) === -1) { words.push(RELATED_WORDS[i]); }
            }
            if (!words.length) { return null; }
            return new RegExp("(?:^|[\\s_-])(?:" + words.join("|") + ")s?(?:$|[\\s_-])", "i");
        })();

        function isInRelatedSection(el) {
            if (!RELATED_SECTION) { return false; }
            var node = el;
            for (var depth = 0; node && depth < 12; depth++) {
                var cls = "";
                var id = "";
                try {
                    cls = (node.getAttribute && node.getAttribute("class")) || "";
                    id = (node.getAttribute && node.getAttribute("id")) || "";
                } catch (e) {}
                if (RELATED_SECTION.test(cls) || RELATED_SECTION.test(id)) { return true; }
                node = node.parentElement;
            }
            return false;
        }

        /// 無限スクロールで継ぎ足された別の記事(data-url等で見分ける)。
        function isInOtherArticleBlock(el) {
            var node = el;
            for (var depth = 0; node && depth < 12; depth++) {
                for (var i = 0; i < ARTICLE_URL_ATTRS.length; i++) {
                    var raw = null;
                    try { raw = node.getAttribute && node.getAttribute(ARTICLE_URL_ATTRS[i]); } catch (e) {}
                    if (!raw) { continue; }
                    var target;
                    try { target = new URL(String(raw), document.baseURI); } catch (e) { continue; }
                    return !sameArticle(target.pathname);
                }
                node = node.parentElement;
            }
            return false;
        }

        function linksWithinArticle(el) {
            var target = linkTarget(el);
            if (!target || target.origin !== document.location.origin) { return false; }
            return sameArticle(target.pathname);
        }

        /// 画面幅の16%以下に描かれた画像(コメント欄のアイコン等)。主役の
        /// 写真があるページだけ。同じ記事の別カットへのサムネイルは残す。
        function isTinyRendered(el) {
            if (!pageHasMainImage()) { return false; }
            if (linksWithinArticle(el)) { return false; }
            var rect;
            try { rect = el.getBoundingClientRect(); } catch (e) { return false; }
            if (!rect || !(rect.width > 0 && rect.height > 0)) { return false; }
            var limit = viewportWidth * TINY_RENDERED_RATIO;
            return rect.width <= limit && rect.height <= limit;
        }

        var siteBrand = (function () {
            var host = String(document.location.hostname || "").toLowerCase();
            var label = host.replace(/^www\./, "").split(".")[0];
            return label.length >= 4 ? label : null;
        })();
        var brandPattern = siteBrand
            ? new RegExp("(?:^|[\\/_-])" + siteBrand.replace(/[.*+?^${}()|[\]\\]/g, "\\$&") + "(?:[\\/_.-]|$)", "i")
            : null;

        /// URLだけで分かる「部品」。ファイル名がバナー/ロゴ等を名乗る、
        /// サイト名入り、部品置き場の直下、WordPressのテーマ/プラグイン配下。
        function assetReason(url) {
            var path;
            try { path = new URL(String(url), document.baseURI).pathname; } catch (e) { return null; }
            var name = path.split("/").pop() || "";
            if (BANNER_FILENAME.test(name)) { return "名前が部品"; }
            if (brandPattern && brandPattern.test(name)) { return "サイト名入り"; }
            if (SITE_ASSET_FILE.test(path) || WP_SITE_ASSET.test(path)) { return "部品置き場"; }
            return null;
        }

        /// `el` を「別の投稿」に回すなら理由、残すなら null。
        function classifyOther(el, url) {
            if (linksElsewhereHere(el)) { return "別投稿リンク"; }
            if (isMemberAvatar(el)) { return "メンバーアイコン"; }
            if (isRelatedThumb(el, url)) { return "関連記事タイル"; }
            if (isOtherPostThumb(el)) { return "別記事へのリンク"; }
            if (isInRelatedSection(el)) { return "囲みの名前"; }
            if (isInOtherArticleBlock(el)) { return "別記事ブロック"; }
            if (isTinyRendered(el)) { return "極小表示"; }
            return null;
        }

        var upgraded = 0;

        /// `renderedOverride`: 同じ写真のページ側の小さい版(imgのsrcと、
        /// そのsrcsetの最大候補)。`box`: 画面上の幅。同じURLが何度も
        /// 置かれているときは、一番大きく表示されている方で仕分けを決める。
        function addURL(url, width, height, origin, why, renderedOverride, box) {
            if (!url) { return; }
            url = String(url).trim();
            if (!url || url.indexOf("data:") === 0) { return; }
            var parsed;
            try {
                parsed = new URL(url, document.baseURI);
            } catch (e) {
                return;
            }
            url = parsed.href;
            // UI部品は捨てずに印を付けて残す: 結果画面の「除外した画像」で
            // 見られるようにするため(ユーザー要望)。
            if (UI_ASSET_PATH.test(url)) { origin = "icon"; why = null; }

            var rendered = null;
            var original = originalOf(parsed);
            if (original) {
                rendered = url;
                url = original;
                width = 0;
                height = 0;
            } else if (renderedOverride) {
                var smaller = null;
                try { smaller = new URL(String(renderedOverride).trim(), document.baseURI); } catch (e) {}
                if (smaller && smaller.protocol !== "data:" && smaller.href !== url) {
                    rendered = smaller.href;
                    width = 0;
                    height = 0;
                }
            }

            origin = origin || "dom";
            var kept = seen[url];
            if (kept) {
                if (rendered && requestedWidth(rendered) > requestedWidth(kept.rendered || "")) {
                    kept.rendered = rendered;
                }
                if ((box || 0) > (kept.box || 0) && kept.origin !== "icon") {
                    kept.box = box || 0;
                    kept.origin = origin;
                    if (origin === "other" && why) { kept.why = why; } else { delete kept.why; }
                }
                return;
            }
            // 名前で分かる部品は、原寸化した後のURLで見る(Next.jsの
            // /_next/image?url=... のままではファイル名が "image" になる)。
            if (origin === "dom") {
                var assetWhy = assetReason(url);
                if (assetWhy) { origin = "other"; why = assetWhy; }
            }
            // 有限数か文字列だけを持たせる: NaN/undefined/nullが1つでも
            // 混ざるとSwift側のJSONデコードが壊れるため。
            var entry = {
                url: url,
                width: (typeof width === "number" && isFinite(width)) ? width : 0,
                height: (typeof height === "number" && isFinite(height)) ? height : 0,
                origin: origin,
                order: order++,
                box: (typeof box === "number" && isFinite(box)) ? box : 0
            };
            if (origin === "other" && why) { entry.why = why; }
            if (rendered) { entry.rendered = rendered; upgraded++; }
            seen[url] = entry;
            images.push(entry);
        }

        function boxWidth(el) {
            try {
                var r = el.getBoundingClientRect();
                return (r && r.width) || 0;
            } catch (e) { return 0; }
        }

        function scanRoot(root) {
            var videoEls = root.querySelectorAll("video");
            for (var v = 0; v < videoEls.length; v++) {
                addURL(videoEls[v].getAttribute("poster"), 0, 0, "video");
                // 動画の上にサムネイルを普通の<img>で重ねるプレイヤーが多い。
                var container = videoEls[v].parentElement;
                if (container) {
                    var covers = container.querySelectorAll("img");
                    for (var c = 0; c < covers.length; c++) {
                        addURL(covers[c].currentSrc || covers[c].src, 0, 0, "video");
                    }
                }
            }

            var videoCovers = instagramVideoCovers(root);
            var imgEls = root.querySelectorAll("img");
            for (var i = 0; i < imgEls.length; i++) {
                var img = imgEls[i];
                var loadedSrc = img.currentSrc || img.src || "";
                // 遅延読み込みの置き石(1x1のdata:)のときは data-src 側に譲る
                // (oricon の写真一覧で30枚中7枚しか取れていなかった)。
                if (/^data:/i.test(loadedSrc) && fromLazyAttrs(img)) { loadedSrc = ""; }
                var url = loadedSrc
                    || bestFromSrcset(img.getAttribute("srcset"))
                    || bestFromSrcset(img.getAttribute("data-srcset"))
                    || fromLazyAttrs(img);
                var why = classifyOther(img, url);
                var imgOrigin = why ? "other"
                    : (videoCovers.indexOf(img) !== -1 ? "video" : "dom");
                var box = boxWidth(img);
                var srcsetBest = bestFromSrcset(img.getAttribute("srcset"));
                // srcsetの大きい方と表示中の小さい方は同じ写真: 1件にまとめる
                // (大きい方を保存、小さい方でプレビュー)。
                if (srcsetBest && url && img.naturalWidth >= 100 && !sameURL(srcsetBest, url)) {
                    addURL(srcsetBest, 0, 0, imgOrigin, why, url, box);
                } else {
                    addURL(url, img.naturalWidth, img.naturalHeight, imgOrigin, why, null, box);
                    addURL(srcsetBest, 0, 0, imgOrigin, why, null, box);
                }
            }

            var sourceEls = root.querySelectorAll("picture source, video source, audio source");
            for (var j = 0; j < sourceEls.length; j++) {
                var src = sourceEls[j];
                addURL(bestFromSrcset(src.getAttribute("srcset")) || src.getAttribute("src"), 0, 0, "dom");
            }

            var posterEls = root.querySelectorAll("[poster]");
            for (var p = 0; p < posterEls.length; p++) {
                addURL(posterEls[p].getAttribute("poster"), 0, 0, "video");
            }

            // headで宣言された先読み画像。Instagramでは開いていない画面の
            // サムネイルなのでカバー扱い、他のサイトでは本文の主役画像
            // (SPAがDOMに出さない原寸)。
            var linkOrigin = isInstagram() ? "meta" : "dom";
            var linkEls = root.querySelectorAll("link[rel~='preload'][as='image'], link[rel~='image_src']");
            for (var l = 0; l < linkEls.length; l++) {
                addURL(linkEls[l].getAttribute("href"), 0, 0, linkOrigin);
                addURL(bestFromSrcset(linkEls[l].getAttribute("imagesrcset")), 0, 0, linkOrigin);
            }
            // サイト自身のアプリアイコン。ページの中身ではない。
            var touchIconEls = root.querySelectorAll("link[rel~='apple-touch-icon']");
            for (var ti = 0; ti < touchIconEls.length; ti++) {
                addURL(touchIconEls[ti].getAttribute("href"), 0, 0, "icon");
            }

            var metaEls = root.querySelectorAll(
                "meta[property='og:image'], meta[property='og:image:url'], "
                + "meta[property='og:image:secure_url'], meta[name='twitter:image'], "
                + "meta[name='twitter:image:src'], meta[itemprop='image']"
            );
            for (var mt = 0; mt < metaEls.length; mt++) {
                addURL(metaEls[mt].getAttribute("content"), 0, 0, "meta");
            }

            var svgUse = root.querySelectorAll("image");
            for (var u = 0; u < svgUse.length; u++) {
                addURL(svgUse[u].getAttribute("href") || svgUse[u].getAttribute("xlink:href"), 0, 0, "dom");
            }

            // realsound.jp(lozadライブラリ)で確認した遅延背景画像属性。
            // <div data-background-image="...">のように非imgのlazy属性として
            // 使われるため、img専用のfromLazyAttrsとは別にここで拾う。
            var bgAttrEls = root.querySelectorAll("[data-background-image]");
            for (var ba = 0; ba < bgAttrEls.length; ba++) {
                var bgAttrWhy = classifyOther(bgAttrEls[ba], null);
                addURL(bgAttrEls[ba].getAttribute("data-background-image"), 0, 0,
                       bgAttrWhy ? "other" : "background", bgAttrWhy);
            }

            if (!withBackgrounds) { return; }

            var allEls = root.querySelectorAll("*");
            var limit = Math.min(allEls.length, 4000);
            for (var k = 0; k < limit; k++) {
                var el = allEls[k];

                if (el.shadowRoot) {
                    try { scanRoot(el.shadowRoot); } catch (e) {}
                }

                var style;
                try {
                    style = getComputedStyle(el);
                } catch (e) {
                    continue;
                }
                var bg = style && style.backgroundImage;
                if (bg && bg.indexOf("url(") !== -1) {
                    var rect = el.getBoundingClientRect();
                    // アイコン枠の小さい背景(スプライト画像)もアイコン扱いで残す。
                    var bgOrigin;
                    var bgWhy = null;
                    if (rect.width < SPRITE_MIN_BOX && rect.height < SPRITE_MIN_BOX) {
                        bgOrigin = "icon";
                    } else {
                        // 背景として置かれた写真にもimgと同じ仕分けを通す。
                        bgWhy = classifyOther(el, null);
                        bgOrigin = bgWhy ? "other" : "background";
                    }
                    var re = /url\(["']?([^"')]+)["']?\)/g;
                    var m;
                    while ((m = re.exec(bg)) !== null) {
                        addURL(m[1], 0, 0, bgOrigin, bgWhy, null, rect.width);
                    }
                }
            }
        }

        /// ページのHTMLテキストに書かれているだけの画像URL。SPAはDOMに
        /// しない原寸URLをインラインJSONに持っていることがある。既定で隠す。
        function collectSource() {
            try {
                var BS = String.fromCharCode(92);
                var html = document.documentElement.innerHTML
                    .split(BS + "u002F").join("/")
                    .split(BS + "u002f").join("/")
                    .split(BS + "/").join("/");
                var QUOTES = String.fromCharCode(34) + String.fromCharCode(39) + String.fromCharCode(96);
                var CLASS = "[^" + BS + "s" + QUOTES + "<>{}" + BS + "[" + BS + "]]";
                var IMAGE_URL = new RegExp(
                    "https?://" + CLASS + "+?" + BS + ".(?:jpe?g|png|gif|webp|heic|heif|bmp|svg|avif)" +
                    "(?:" + BS + "?" + CLASS + "*)?", "gi");
                var hit;
                var found = 0;
                var before = images.length;
                while ((hit = IMAGE_URL.exec(html)) !== null && found < 800) {
                    addURL(hit[0], 0, 0, "source");
                    found++;
                }
                notes.push("ソース走査: 一致" + found + "件・新規" + (images.length - before) + "件");
            } catch (e) {
                notes.push("ソース走査に失敗: " + e);
            }
        }

        /// 記事ごとのフォルダに画像を置くサイトで、別の記事のフォルダに
        /// ある画像を外す(xtrend.nikkei.com の「次に読む」)。このページ
        /// 自身の画像がそのフォルダの下に実際にあるときだけ働く。
        function demoteForeignArticleImages() {
            var top = pathSegments(hereTrimmed);
            if (top.length < 2) { return 0; }
            var prefix = hereTrimmed + "/";
            var base = "/" + top[0] + "/";
            var paths = [];
            var ownFolderUsed = false;
            var i, parsed;
            for (i = 0; i < images.length; i++) {
                parsed = null;
                try { parsed = new URL(images[i].url, document.baseURI); } catch (e) {}
                paths.push(parsed);
                if (parsed && parsed.pathname.indexOf(prefix) === 0) { ownFolderUsed = true; }
            }
            if (!ownFolderUsed) { return 0; }
            var demoted = 0;
            for (i = 0; i < images.length; i++) {
                var o = images[i].origin;
                if (o !== "dom" && o !== "background" && o !== "source") { continue; }
                parsed = paths[i];
                if (!parsed) { continue; }
                if (parsed.pathname.indexOf(prefix) === 0) { continue; }
                if (parsed.pathname.indexOf(base) !== 0) { continue; }
                images[i].origin = "other";
                images[i].why = "別記事のフォルダ";
                demoted++;
            }
            return demoted;
        }

        function galleryPageOf(img) {
            var link = linkTarget(img);
            if (!link) { return null; }
            if (link.protocol !== document.location.protocol
                || link.host !== document.location.host) { return null; }
            if (link.pathname.replace(/\/+$/, "") === hereTrimmed) { return "self"; }
            if (!sameArticle(link.pathname)) { return null; }
            link.hash = "";
            return link.href;
        }

        function intrinsicArea(el) {
            var w = el.naturalWidth || 0;
            var h = el.naturalHeight || 0;
            if (!(w > 0) || !(h > 0)) { return 0; }
            return w * h;
        }

        /// 一覧が小さなサムネイルで、原寸のURLが写真ごとの個別ページにしか
        /// 書かれていないギャラリー(oricon の写真一覧)。ここでは読みに
        /// 行かず、取得先(page)を添えるだけ。読むのは保存・拡大の瞬間に、
        /// 選ばれた分だけ(OriginalPageResolver)。
        function markGalleryOriginalPages() {
            var imgEls;
            try { imgEls = document.querySelectorAll("a[href] img"); } catch (e) { return; }
            var selfLinked = [];
            var candidates = [];
            for (var i = 0; i < imgEls.length; i++) {
                var img = imgEls[i];
                var raw = img.currentSrc || img.src || "";
                if (/^data:/i.test(raw) && fromLazyAttrs(img)) { raw = ""; }
                if (!raw) { raw = fromLazyAttrs(img) || ""; }
                if (!raw) { continue; }
                var thumb;
                try { thumb = new URL(raw, document.baseURI).href; } catch (e) { continue; }
                var entry = seen[thumb];
                // seenに無いのは原寸URLへの置き換えが既に効いている印。
                if (!entry || entry.origin !== "dom" || entry.rendered || entry.page) { continue; }
                var page = galleryPageOf(img);
                if (!page) { continue; }
                if (page === "self") { selfLinked.push(entry); continue; }
                candidates.push({ entry: entry, page: page, area: intrinsicArea(img) });
            }
            // 主役の写真(サムネイルの中央値の3倍以上の画素数)は外す: 主役が
            // 「次の写真へ」のリンクに包まれていると、次の写真を取ってしまう。
            var leads = 0;
            if (candidates.length >= GALLERY_MIN_PAGES) {
                var areas = [];
                for (var a = 0; a < candidates.length; a++) {
                    if (candidates[a].area >= LOADED_AREA_FLOOR) { areas.push(candidates[a].area); }
                }
                if (areas.length >= GALLERY_MIN_PAGES) {
                    areas.sort(function (x, y) { return x - y; });
                    var ceiling = areas[Math.floor(areas.length / 2)] * LEAD_AREA_MULTIPLE;
                    var keptCands = [];
                    for (var b = 0; b < candidates.length; b++) {
                        if (candidates[b].area >= ceiling) { leads++; continue; }
                        keptCands.push(candidates[b]);
                    }
                    candidates = keptCands;
                }
            }
            // 同じページを2つが押さえたら、小さい方(一覧のサムネイル)に渡す。
            var claimed = {};
            for (var c = 0; c < candidates.length; c++) {
                var holder = claimed[candidates[c].page];
                if (!holder || candidates[c].area < holder.area) { claimed[candidates[c].page] = candidates[c]; }
            }
            var marked = [];
            for (var d = 0; d < candidates.length; d++) {
                if (claimed[candidates[d].page] !== candidates[d]) { continue; }
                candidates[d].entry.page = candidates[d].page;
                marked.push(candidates[d].entry);
            }
            if (marked.length < GALLERY_MIN_PAGES) {
                for (var k = 0; k < marked.length; k++) { delete marked[k].page; }
                return;
            }
            notes.push("原寸の取得先を添えた: " + marked.length + "枚"
                       + (leads ? " / 主役として外した" + leads + "枚" : ""));
            // 今開いているページ自身を指すサムネイルは、この画面の主役の縮小版。
            if (selfLinked.length && pageHasMainImage()) {
                for (var s = 0; s < selfLinked.length; s++) {
                    selfLinked[s].origin = "other";
                    selfLinked[s].why = "今開いている写真の縮小版";
                }
                notes.push("今開いている写真の縮小版を外した: " + selfLinked.length + "枚");
            }
        }

        try { scanRoot(document); } catch (e) {}

        // 通常サイトでは常時オンにするとトラッカーの計測用画像等のノイズが
        // 増えるだけなので、DOM収集が原理的に無力なFlutterページに限る。
        var flutter = isFlutterPage();
        if (flutter) {
            var netImgs = resourceTimingImages();
            for (var ni = 0; ni < netImgs.length; ni++) {
                addURL(netImgs[ni], 0, 0, "network");
            }
        }

        var frames = document.querySelectorAll("iframe, frame");
        for (var f = 0; f < frames.length; f++) {
            try {
                var doc = frames[f].contentDocument;
                if (doc) { scanRoot(doc); }
            } catch (e) {
                // クロスオリジンのframeは読めないのでスキップ。
            }
        }

        // ソース走査・フォルダ判定・ギャラリーは全体を見る回だけ(カルーセル
        // 送りの途中で毎回やると重い)。Flutterページはソースに写真が無い。
        if (withBackgrounds && !flutter) {
            collectSource();
            var demoted = demoteForeignArticleImages();
            if (demoted) { notes.push("別記事のフォルダの画像: " + demoted + "件"); }
            try { markGalleryOriginalPages(); } catch (e) { notes.push("原寸の取得先で例外: " + e); }
        }

        // Flutter製ページは画面をCanvasに描くので、og:image等のメタ画像は
        // 画面に出ている写真ではなく、SNS共有用のカバー画像(日向坂46
        // メッセージの/ogp_image.png 1200x638で確認)。結果画面では
        // 「除外した画像」フィルターでだけ見せる。
        // Instagramのog:imageも同様: 画面遷移しても書き換わらず、別の投稿の
        // 画像を指していることがある(ImageSaverで確認)。
        var instagram = isInstagram();
        var whyCounts = {};
        images.sort(function (a, b) { return a.order - b.order; });
        for (var si = 0; si < images.length; si++) {
            var img2 = images[si];
            delete img2.order;
            delete img2.box;
            var o = img2.origin;
            if ((flutter || instagram) && o === "meta") { img2.excluded = "cover"; }
            if (o === "other") {
                img2.excluded = "other";
                var w = img2.why || "その他";
                whyCounts[w] = (whyCounts[w] || 0) + 1;
            }
            if (o === "source") { img2.excluded = "source"; }
            if (instagram && o === "video") { img2.excluded = "video"; }
            if (o === "icon") {
                img2.excluded = /\/splash\/img\//i.test(img2.url) ? "splash" : "icon";
            }
        }

        if (withBackgrounds) {
            var reasons = [];
            for (var rk in whyCounts) {
                if (Object.prototype.hasOwnProperty.call(whyCounts, rk)) { reasons.push(rk + " " + whyCounts[rk]); }
            }
            notes.push("別の投稿・部品として隠した: "
                       + (reasons.length ? reasons.join(" / ") : "なし")
                       + (pageHasMainImage() ? "" : " (主役の写真が無いページのため、リンク・極小表示の判定は無効)"));
            if (upgraded) { notes.push("縮小指定を外して原寸URLに: " + upgraded + "件"); }
            notes.push("合計" + images.length + "件 / " + (Date.now() - startedAt) + "ms");
            lastCollectNote = "抽出の仕分け: " + notes.join(" / ");
        }
        return images;
    }

    function collectNote() { return lastCollectNote; }

    // --- カルーセル送り(Instagramの投稿ページのみ) ---------------------
    // Instagramは表示中のスライドと両隣しかDOMに置かず、残りはページの
    // どこにも無いので、矢印を押して送るしかない(ImageSaverと同じ方式)。
    // 共有シートと違ってアプリ内では時間の制約が緩いので、端まで送り切って
    // から元のスライドへ戻す。
    var NEXT_LABEL = /^(next|次へ|次の.{0,6})$/i;
    var PREV_LABEL = /^(prev|previous|back|前へ|戻る|前の.{0,6})$/i;
    var lastWalkNote = "";

    function containerOf(element) {
        var container = element.closest("article, [role='dialog'], main, section");
        if (container) { return container; }
        var node = element;
        for (var up = 0; up < 6 && node.parentElement; up++) { node = node.parentElement; }
        return node;
    }

    // 矢印ではなく一番大きい画像から探す: 最後のスライドで開くと「次へ」が無い。
    function galleryScope() {
        var imgs = document.querySelectorAll("img");
        var best = null;
        var bestArea = 0;
        for (var i = 0; i < imgs.length; i++) {
            var rect = imgs[i].getBoundingClientRect();
            var area = rect.width * rect.height;
            if (area > bestArea) { bestArea = area; best = imgs[i]; }
        }
        return best ? containerOf(best) : null;
    }

    function findControl(pattern, scope) {
        var candidates = (scope || document).querySelectorAll("[aria-label]");
        for (var i = 0; i < candidates.length; i++) {
            var el = candidates[i];
            if (!pattern.test((el.getAttribute("aria-label") || "").trim())) { continue; }
            var role = (el.getAttribute("role") || "").toLowerCase();
            if (el.tagName !== "BUTTON" && role !== "button") { continue; }
            // リンクは押さない: ページごと移動して抽出が台無しになる。
            if (el.tagName === "A" || el.closest("a")) { continue; }
            if (!el.offsetParent) { continue; }
            return el;
        }
        return null;
    }

    function slideSignature(scope) {
        var imgs = (scope || document).querySelectorAll("img");
        var sig = imgs.length + ":";
        for (var i = 0; i < imgs.length && i < 8; i++) {
            sig += (imgs[i].currentSrc || imgs[i].src || "").slice(-24) + ",";
        }
        return sig;
    }

    function sleep(ms) { return new Promise(function (r) { setTimeout(r, ms); }); }

    // 押して、スライドが実際に変わるまで(最大1秒)待つ。変わらなければfalse。
    async function clickAndSettle(control, scope) {
        var before = slideSignature(scope);
        var startPath = document.location.pathname;
        try { control.click(); } catch (e) { return false; }
        for (var waited = 0; waited < 1000; waited += 30) {
            await sleep(30);
            if (document.location.pathname !== startPath) { return false; }
            if (slideSignature(scope) !== before) { await sleep(60); return true; }
        }
        return false;
    }

    async function collectAsync(withBackgrounds) {
        var first = collect(withBackgrounds);
        lastWalkNote = "";
        if (!isInstagram() || !onPostPermalink()) { return first; }

        var startedAt = Date.now();
        var ordered = first.slice();
        var byURL = {};
        for (var i = 0; i < first.length; i++) { byURL[first[i].url] = true; }
        function merge(items, prepend) {
            var fresh = [];
            for (var j = 0; j < items.length; j++) {
                if (byURL[items[j].url]) { continue; }
                byURL[items[j].url] = true;
                fresh.push(items[j]);
            }
            ordered = prepend ? fresh.concat(ordered) : ordered.concat(fresh);
            return fresh.length;
        }

        var scope = galleryScope();
        var back = 0;
        var forward = 0;
        var notes = [];
        // 先に先頭まで戻る: 途中のスライドで開いた投稿の前半を拾うため。
        while (back < 40 && Date.now() - startedAt < 12000) {
            var prev = findControl(PREV_LABEL, scope);
            if (!prev || !(await clickAndSettle(prev, scope))) { break; }
            back++;
            merge(collect(false), true);
        }
        while (forward < 60 && Date.now() - startedAt < 24000) {
            var next = findControl(NEXT_LABEL, null);
            if (!next || !(await clickAndSettle(next, scope))) { break; }
            forward++;
            merge(collect(false), false);
        }
        notes.push("戻る" + back + "回・次へ" + forward + "回");
        // 開いていたスライドへ戻す(送り切った位置から back - forward 枚分)。
        var restore = forward - back;
        var restored = 0;
        while (restored < restore && Date.now() - startedAt < 32000) {
            var p = findControl(PREV_LABEL, scope);
            if (!p || !(await clickAndSettle(p, scope))) { break; }
            restored++;
        }
        if (restore > 0) { notes.push("元のスライドへ" + restored + "/" + restore + "枚戻した"); }
        notes.push((Date.now() - startedAt) + "ms");
        lastWalkNote = "カルーセル送り: " + notes.join(" / ");
        return ordered;
    }

    function walkNote() { return lastWalkNote; }

    // 一部サイトは「touchstart(=指が触れた瞬間)」にJSでimgのsrcを本物→
    // 別画像(ロゴ・プレースホルダー等)へすり替え、長押しで検出される頃には
    // 偽物しか残っていない、という保存妨害をしてくる(櫻坂46メッセージの
    // splash/img/light-3x.pngで確認)。キャプチャフェーズのリスナーは同じ
    // イベントに対するバブルフェーズのリスナー(サイト側の多くはこちらで
    // 実装されている)より必ず先に走るので、すり替えが起きる前の本来のsrcを
    // ここで先取りして憶えておき、findImageAtではそちらを優先する。
    var lastRealSrc = new WeakMap();
    function rememberRealSrc(target) {
        var node = target;
        for (var steps = 0; steps < 8 && node; steps++) {
            if (node.tagName === "IMG") {
                var src = node.currentSrc || node.src;
                if (src) { lastRealSrc.set(node, src); }
            }
            node = node.parentElement;
        }
    }
    document.addEventListener("touchstart", function (e) { rememberRealSrc(e.target); }, { capture: true, passive: true });
    document.addEventListener("mousedown", function (e) { rememberRealSrc(e.target); }, { capture: true, passive: true });

    function imageURLFromElement(node) {
        if (node.tagName === "IMG") {
            var url = lastRealSrc.get(node) || node.currentSrc || node.src
                || bestFromSrcset(node.getAttribute("srcset"))
                || fromLazyAttrs(node);
            if (url && !UI_ASSET_PATH.test(url)) { return resolve(url); }
        }
        var style;
        try { style = getComputedStyle(node); } catch (e) { style = null; }
        var bg = style && style.backgroundImage;
        if (bg && bg.indexOf("url(") !== -1) {
            var m = /url\(["']?([^"')]+)["']?\)/.exec(bg);
            if (m && !UI_ASSET_PATH.test(m[1])) { return resolve(m[1]); }
        }
        return null;
    }

    function describeNode(node) {
        var desc = node.tagName || "?";
        if (node.id) { desc += "#" + node.id; }
        if (node.className && typeof node.className === "string" && node.className.trim()) {
            desc += "." + node.className.trim().split(/\s+/).join(".");
        }
        return desc;
    }

    // 長押しされた座標から画像URLを1件特定する。カード型レイアウトでは
    // クリック計測用の透明な<a>がimgの真上に重なっていることが多く、
    // 「先頭要素から親を辿る」だけでは画像を素通りしてしまう。
    // elementsFromPointでその座標に重なっている全要素(手前から奥へ)を
    // 取得し、それぞれについて自身と祖先8階層を調べる。
    //
    // trail(診断用)には、調べた各要素についてタグ/class、imgならsrcと
    // lastRealSrcの値、その要素での判定結果を積んでいく。保護妨害の
    // パターンはサイトごとに違う(すり替え・重なり・遅延等)ので、実機の
    // ログからどのパターンかを直接読み取れるようにするためのもの。
    function findImageAtDebug(x, y) {
        var stack;
        try {
            stack = document.elementsFromPoint(x, y);
        } catch (e) {
            stack = [];
        }
        if (!stack || !stack.length) {
            var single;
            try { single = document.elementFromPoint(x, y); } catch (e2) { single = null; }
            stack = single ? [single] : [];
        }

        var trail = [];
        for (var i = 0; i < stack.length; i++) {
            var node = stack[i];
            for (var steps = 0; steps < 8 && node; steps++) {
                var isImg = node.tagName === "IMG";
                var found = imageURLFromElement(node);
                trail.push({
                    i: i, steps: steps, node: describeNode(node),
                    currentSrc: isImg ? (node.currentSrc || node.src || null) : null,
                    remembered: isImg ? (lastRealSrc.get(node) || null) : null,
                    result: found || null
                });
                if (found) { return { url: found, trail: trail }; }
                node = node.parentElement;
            }
        }
        return { url: null, trail: trail };
    }

    function findImageAt(x, y) {
        return findImageAtDebug(x, y).url;
    }

    function resolve(url) {
        try {
            var parsed = new URL(url, document.baseURI);
            return originalOf(parsed) || parsed.href;
        } catch (e) {
            return url;
        }
    }

    // 画面(URL)が変わる直前に呼ぶ: その時点までに読み込まれた写真を拾って
    // 通信履歴を空にする。拾わずに消すと、トークを開いた直後に別画面へ
    // 移った場合、そのトークの写真が一度も記録されないまま失われていた
    // (戻ってもサイトは写真をキャッシュから描くため通信が起きない)。
    function harvestNetworkImages() {
        if (isFlutterPage()) { return resourceTimingImages(); }
        try { performance.clearResourceTimings(); } catch (e) {}
        return [];
    }

    window.__ImageBrowserCollector = {
        collect: collect,
        collectAsync: collectAsync,
        walkNote: walkNote,
        collectNote: collectNote,
        harvestNetworkImages: harvestNetworkImages,
        findImageAt: findImageAt,
        findImageAtDebug: findImageAtDebug,
        isFlutterPage: isFlutterPage,
        findCanvasRegionAt: findCanvasRegionAt,
        resourceTimingBreakdown: resourceTimingBreakdown
    };
})();
