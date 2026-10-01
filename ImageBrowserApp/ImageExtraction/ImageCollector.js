// 画像収集ロジック。ImageSaver(Safari Action Extension)のAction.jsから
// 収集アルゴリズムの核(img/picture/source/poster/CSS背景画像/OGP/SVG/
// lazy-load属性/リサイズURL復元)を移植し、拡張機能特有の複雑さ
// (completionFunction前提のタイムアウト管理、カルーセル自動送り、
// サイト固有ハック)を取り除いて単純化したもの。
//
// window.__ImageBrowserCollector として以下を公開する:
//   collect(withBackgrounds) -> Array<{url, width, height, origin}> を同期的に返す
//   findImageAt(x, y)        -> 座標上の画像URL(文字列)、無ければnull
//
// フルブラウザはユーザー自身がページを操作してから抽出を呼べるため、
// Action.js にあったカルーセル自動送りは不要(ページを開いた一瞬しか
// チャンスが無い拡張機能ならではの事情だった)。
(function () {
    "use strict";

    // インターフェース部品(スピナー・再生ボタン等)の静的リソースパス。
    // img_protect.pngはmdpr.jp(モデルプレス)の写真詳細ページで、本物の
    // サムネイルの真上に重なる保護用オーバーレイ画像。実在するsrcを持つ
    // ため素通りせず、長押しでこれを検出してしまうと本物の写真まで
    // 辿り着けない(elementsFromPointのスタックで先に見つかるため)。
    // splash/img/ はFlutter Web標準テンプレートの起動スプラッシュ画像
    // (light-3x.png等)の定位置。さくら坂46メッセージ(Flutter製アプリ)で、
    // ページ内で唯一実在するimg要素がこれだったため、長押しのたびに
    // これだけが検出されてしまっていた。除外することで、Canvas描画への
    // フォールバック(下のisFlutterPage/isCanvasRenderedPage参照)に
    // ちゃんと繋がるようにする。
    var UI_ASSET_PATH = /\/rsrc\.php\/|static\.cdninstagram\.com|\/static\.xx\.fbcdn\.net\/|\/img_protect\.png|\/splash\/img\//i;

    // .../<hash>/1200_1200_102400.jpg のようなリサイズ配信URLから
    // 元画像URLを復元する。
    var RESIZED_PATH = /^(.*\/[0-9a-f]{16,})\/\d+_\d+_\d+(\.(?:jpe?g|png|gif))$/i;
    var REQUESTED_BOX = /\/(\d+)_\d+_\d+\.[a-z]+$/i;

    // モデルプレス(img-mdpr.freetls.fastly.net)・音楽ナタリー(ogre.natalie.mu)
    // で確認したクエリパラメータ型のリサイズ指定。パスにhashが埋め込まれる
    // RESIZED_PATHとは別方式で、ドメインごとにキー名が違うため、確認できた
    // 2ホストだけに限定したホワイトリストとして持つ(未確認のサイトへ
    // 汎用的にクエリ除去をかけると、認証・署名用のクエリまで壊しかねない)。
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

    function originalOf(parsed) {
        if (!RESIZED_PATH.test(parsed.pathname)) { return null; }
        var full = new URL(parsed.href);
        full.pathname = parsed.pathname.replace(RESIZED_PATH, "$1$2");
        return full.href;
    }

    function requestedWidth(href) {
        var m;
        try { m = REQUESTED_BOX.exec(new URL(href).pathname); } catch (e) { return 0; }
        return m ? parseInt(m[1], 10) : 0;
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
    // 通常の<img>/CSS背景画像としてDOMに一切現れない(さくら坂46メッセージで
    // 確認)。<flutter-view>/<flt-glass-pane>はFlutterのWeb出力が必ず生成する
    // ルート要素なので、これの有無でCanvas描画アプリかどうかを判定する。
    function isFlutterPage() {
        return !!document.querySelector("flutter-view, flt-glass-pane");
    }

    // DOMを一切見ずに、ブラウザが実際に読み込んだ画像のURL一覧を
    // Resource Timing APIから拾う。Canvas描画アプリでは、写真データ自体は
    // 普通にHTTPで取得されて画面に描かれているので、DOM収集の穴を
    // この方法で埋められる(幅/高さの情報は無いため0のまま)。
    // さくら坂46メッセージ(CloudFront配信)で確認した構造: 同じ写真が
    // /messages/files/<name>.jpg(フルサイズ)と/messages/thumbnails/<name>.jpg
    // (縮小版)の2本立てで別URLとして両方読み込まれる。フルサイズは
    // 同じ通信履歴スキャンで別途拾えるので、縮小版側は除外して重複を防ぐ。
    var THUMBNAIL_PATH = /\/thumbnails\//i;

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
                if (THUMBNAIL_PATH.test(url)) { continue; }
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

    function collect(withBackgrounds) {
        var seen = {};
        var images = [];
        var order = 0;

        function addURL(url, width, height, origin) {
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
            if (UI_ASSET_PATH.test(url)) { return; }

            var rendered = null;
            var original = originalOf(parsed) || originalOfQuery(parsed);
            if (original) {
                rendered = url;
                url = original;
                width = 0;
                height = 0;
            }

            var kept = seen[url];
            if (kept) {
                if (rendered && requestedWidth(rendered) > requestedWidth(kept.rendered || "")) {
                    kept.rendered = rendered;
                }
                return;
            }
            // 有限数か文字列だけを持たせる: NaN/undefined/nullが1つでも
            // 混ざるとSwift側のJSONデコードが壊れるため。
            var entry = {
                url: url,
                width: (typeof width === "number" && isFinite(width)) ? width : 0,
                height: (typeof height === "number" && isFinite(height)) ? height : 0,
                origin: origin || "dom",
                order: order++
            };
            if (rendered) { entry.rendered = rendered; }
            seen[url] = entry;
            images.push(entry);
        }

        function scanRoot(root) {
            var videoEls = root.querySelectorAll("video");
            for (var v = 0; v < videoEls.length; v++) {
                addURL(videoEls[v].getAttribute("poster"), 0, 0, "video");
            }

            var imgEls = root.querySelectorAll("img");
            for (var i = 0; i < imgEls.length; i++) {
                var img = imgEls[i];
                var url = img.currentSrc || img.src
                    || bestFromSrcset(img.getAttribute("srcset"))
                    || bestFromSrcset(img.getAttribute("data-srcset"))
                    || fromLazyAttrs(img);
                addURL(url, img.naturalWidth, img.naturalHeight, "dom");
                addURL(bestFromSrcset(img.getAttribute("srcset")), 0, 0, "dom");
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
                addURL(bgAttrEls[ba].getAttribute("data-background-image"), 0, 0, "background");
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
                    if (rect.width < SPRITE_MIN_BOX && rect.height < SPRITE_MIN_BOX) { continue; }
                    var re = /url\(["']?([^"')]+)["']?\)/g;
                    var m;
                    while ((m = re.exec(bg)) !== null) {
                        addURL(m[1], 0, 0, "background");
                    }
                }
            }
        }

        try { scanRoot(document); } catch (e) {}

        // 通常サイトでは常時オンにするとトラッカーの計測用画像等のノイズが
        // 増えるだけなので、DOM収集が原理的に無力なFlutterページに限る。
        if (isFlutterPage()) {
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

        images.sort(function (a, b) { return a.order - b.order; });
        for (var si = 0; si < images.length; si++) {
            delete images[si].order;
        }
        return images;
    }

    // 一部サイトは「touchstart(=指が触れた瞬間)」にJSでimgのsrcを本物→
    // 別画像(ロゴ・プレースホルダー等)へすり替え、長押しで検出される頃には
    // 偽物しか残っていない、という保存妨害をしてくる(さくら坂46メッセージの
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

    window.__ImageBrowserCollector = {
        collect: collect,
        findImageAt: findImageAt,
        findImageAtDebug: findImageAtDebug,
        isFlutterPage: isFlutterPage,
        findCanvasRegionAt: findCanvasRegionAt,
        resourceTimingBreakdown: resourceTimingBreakdown
    };
})();
