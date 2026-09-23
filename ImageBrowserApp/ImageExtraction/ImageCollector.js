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
    var UI_ASSET_PATH = /\/rsrc\.php\/|static\.cdninstagram\.com|\/static\.xx\.fbcdn\.net\//i;

    // .../<hash>/1200_1200_102400.jpg のようなリサイズ配信URLから
    // 元画像URLを復元する。
    var RESIZED_PATH = /^(.*\/[0-9a-f]{16,})\/\d+_\d+_\d+(\.(?:jpe?g|png|gif))$/i;
    var REQUESTED_BOX = /\/(\d+)_\d+_\d+\.[a-z]+$/i;

    var LAZY_ATTRS = [
        "data-src", "data-original", "data-lazy-src", "data-lazy",
        "data-image", "data-url", "data-hi-res-src", "data-large-file"
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
            var original = originalOf(parsed);
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

    // 長押しされた座標から画像URLを1件特定する。img/picture/背景画像の順で
    // 直近の要素を辿る。
    function findImageAt(x, y) {
        var el;
        try { el = document.elementFromPoint(x, y); } catch (e) { return null; }
        if (!el) { return null; }

        var node = el;
        for (var steps = 0; steps < 8 && node; steps++) {
            if (node.tagName === "IMG") {
                var url = node.currentSrc || node.src
                    || bestFromSrcset(node.getAttribute("srcset"))
                    || fromLazyAttrs(node);
                if (url) { return resolve(url); }
            }
            var style;
            try { style = getComputedStyle(node); } catch (e) { style = null; }
            var bg = style && style.backgroundImage;
            if (bg && bg.indexOf("url(") !== -1) {
                var m = /url\(["']?([^"')]+)["']?\)/.exec(bg);
                if (m) { return resolve(m[1]); }
            }
            node = node.parentElement;
        }
        return null;
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
        findImageAt: findImageAt
    };
})();
