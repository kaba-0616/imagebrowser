// ページが使っている動画・音声のURLを集める(document開始時に、全フレームへ注入)。
//
// 見つけ方は4通り。どれもページの動作は変えない(元の関数をそのまま呼び、
// 応答は読むだけ。失敗はすべて握りつぶす)。
//   1. fetch / XMLHttpRequest のURLと Content-Type(hls.js などのプレイヤーが
//      .m3u8 を取りに行くのはここ)
//   2. <video> / <audio> / <source> 要素の src(Safari標準のHLS再生はここ)
//   3. 再生イベント(play / loadedmetadata)が起きた要素の currentSrc
//   4. Resource Timing(要素が直接読み込んだファイル)
//
// トーク(message.sakurazaka46.com など)は Flutter 製で画面が canvas なので、
// 要素からは見つからない。動画・ボイスの一覧は NetworkTap.js のタイムライン
// 取得(画像と同じ仕組み)から作る(WebViewController.talkMedia)。
//
// 報告先は webkit.messageHandlers.videoBrowserMedia。
(function () {
    "use strict";
    if (window.__VideoBrowserSniffer) { return; }
    window.__VideoBrowserSniffer = true;

    var MEDIA_URL = /\.(m3u8|mpd|mp4|m4v|mov|webm|m4a|mp3|aac|wav|ogg|oga|opus|flac)(\?|#|$)/i;
    var MEDIA_TYPE = /^(video|audio)\/|mpegurl|dash\+xml/i;
    var reported = {};

    function post(payload) {
        try { window.webkit.messageHandlers.videoBrowserMedia.postMessage(payload); } catch (e) {}
    }

    function absolute(url) {
        try { return new URL(String(url), location.href).href; } catch (e) { return ""; }
    }

    function pageTitle() {
        try {
            var og = document.querySelector('meta[property="og:title"]');
            return (og && og.content) || document.title || "";
        } catch (e) { return ""; }
    }

    // その動画・音声だけの名前: title / aria-label / 囲む figure の説明文。
    // 無ければ空(アプリ側でページのタイトルを使う)。
    function elementLabel(el) {
        try {
            var label = el.getAttribute("title") || el.getAttribute("aria-label") || "";
            if (!label && el.closest) {
                var figure = el.closest("figure");
                var caption = figure && figure.querySelector("figcaption");
                if (caption) { label = caption.textContent || ""; }
            }
            return label.replace(/\s+/g, " ").trim().slice(0, 80);
        } catch (e) { return ""; }
    }

    function report(url, info) {
        url = absolute(url);
        if (!/^https?:/i.test(url)) { return; }
        info = info || {};
        var key = url + "|" + (info.poster || "") + "|" + (info.duration || "") + "|" + (info.label || "");
        if (reported[key]) { return; }
        reported[key] = 1;
        post({
            kind: "media",
            url: url,
            ctype: String(info.ctype || ""),
            via: String(info.via || ""),
            poster: info.poster ? absolute(info.poster) : "",
            duration: isFinite(info.duration) ? Number(info.duration) : 0,
            audio: !!info.audio,
            title: pageTitle(),
            label: String(info.label || ""),
            frame: window.top === window ? "main" : location.host
        });
    }

    function looksLikeMedia(url, ctype) {
        return MEDIA_URL.test(String(url)) || MEDIA_TYPE.test(String(ctype || ""));
    }

    // ---- 1. fetch / XMLHttpRequest ----
    var originalFetch = window.fetch;
    if (originalFetch) {
        window.fetch = function (input, init) {
            var url = "";
            try {
                url = typeof input === "string" ? input : (input && input.url) || String(input);
                if (MEDIA_URL.test(url)) { report(url, { via: "fetch" }); }
            } catch (e) {}
            var promise = originalFetch.apply(this, arguments);
            try {
                promise.then(function (res) {
                    try {
                        var ctype = res.headers.get("content-type") || "";
                        if (MEDIA_TYPE.test(ctype)) { report(res.url || url, { via: "fetch", ctype: ctype }); }
                    } catch (e) {}
                }, function () {});
            } catch (e) {}
            return promise;
        };
    }

    var originalOpen = XMLHttpRequest.prototype.open;
    var originalSend = XMLHttpRequest.prototype.send;
    XMLHttpRequest.prototype.open = function (method, url) {
        try {
            this.__vbURL = String(url);
            if (MEDIA_URL.test(this.__vbURL)) { report(this.__vbURL, { via: "xhr" }); }
        } catch (e) {}
        return originalOpen.apply(this, arguments);
    };
    XMLHttpRequest.prototype.send = function () {
        var xhr = this;
        try {
            xhr.addEventListener("load", function () {
                try {
                    var ctype = xhr.getResponseHeader("content-type") || "";
                    var url = xhr.responseURL || xhr.__vbURL;
                    if (MEDIA_TYPE.test(ctype)) { report(url, { via: "xhr", ctype: ctype }); }
                } catch (e) {}
            });
        } catch (e) {}
        return originalSend.apply(this, arguments);
    };

    // ---- 2. / 3. 要素 ----
    // 遅延読み込みのプレイヤーは、画面に入るまで src を空にして別の属性に置いている。
    var LAZY_ATTRS = ["data-src", "data-video-src", "data-video", "data-lazy-src", "data-original"];

    function elementURLs(el) {
        var urls = [];
        if (!el.getAttribute) { return urls; }
        if (el.getAttribute("src")) { urls.push(el.getAttribute("src")); }
        for (var i = 0; i < LAZY_ATTRS.length; i++) {
            var v = el.getAttribute(LAZY_ATTRS[i]);
            if (v && MEDIA_URL.test(v)) { urls.push(v); }
        }
        return urls;
    }

    function fromElement(el, via) {
        try {
            var audio = el.tagName === "AUDIO";
            var poster = el.getAttribute && (el.getAttribute("poster") || el.getAttribute("data-poster"));
            var duration = el.duration;
            var urls = [];
            if (el.currentSrc) { urls.push(el.currentSrc); }
            urls = urls.concat(elementURLs(el));
            var sources = el.querySelectorAll ? el.querySelectorAll("source") : [];
            for (var i = 0; i < sources.length; i++) {
                urls = urls.concat(elementURLs(sources[i]));
            }
            for (var j = 0; j < urls.length; j++) {
                // blob:(MediaSource) は中身のURLではない。元のプレイリストは
                // fetch/XHR 側で拾っている。
                if (/^(blob|data|mediastream):/i.test(urls[j])) { continue; }
                report(urls[j], { via: via, poster: poster, duration: duration, audio: audio, label: elementLabel(el) });
            }
        } catch (e) {}
    }

    window.__VideoBrowserScan = function () {
        try {
            var els = document.querySelectorAll("video, audio");
            for (var i = 0; i < els.length; i++) { fromElement(els[i], "element"); }
            if (window.performance && performance.getEntriesByType) {
                var entries = performance.getEntriesByType("resource");
                for (var k = 0; k < entries.length; k++) {
                    if (MEDIA_URL.test(entries[k].name)) { report(entries[k].name, { via: "timing" }); }
                }
            }
        } catch (e) {}
        return true;
    };

    // スクロールで増える一覧(SNS のタイムライン・まとめ記事)は、再生も通信も
    // 起きないまま <video> だけが足されていく。DOM の変化とスクロールのたびに
    // (0.6秒にまとめて)探し直し、ツールバーの件数をその場で増やす。
    var scanTimer = null;
    function scheduleScan() {
        if (scanTimer) { return; }
        scanTimer = setTimeout(function () {
            scanTimer = null;
            window.__VideoBrowserScan();
        }, 600);
    }
    try {
        new MutationObserver(function (mutations) {
            for (var i = 0; i < mutations.length; i++) {
                var m = mutations[i];
                if (m.type === "attributes") {
                    if (/^(VIDEO|AUDIO|SOURCE)$/.test(m.target.tagName)) { scheduleScan(); return; }
                    continue;
                }
                for (var j = 0; j < m.addedNodes.length; j++) {
                    var n = m.addedNodes[j];
                    if (n.nodeType !== 1) { continue; }
                    if (/^(VIDEO|AUDIO|SOURCE)$/.test(n.tagName) || (n.querySelector && n.querySelector("video, audio"))) {
                        scheduleScan();
                        return;
                    }
                }
            }
        }).observe(document, {
            childList: true, subtree: true,
            attributes: true, attributeFilter: ["src", "poster"].concat(LAZY_ATTRS)
        });
    } catch (e) {}
    window.addEventListener("scroll", scheduleScan, { passive: true, capture: true });
    document.addEventListener("DOMContentLoaded", scheduleScan);

    ["play", "loadedmetadata", "durationchange"].forEach(function (type) {
        document.addEventListener(type, function (ev) {
            var t = ev.target;
            if (t && (t.tagName === "VIDEO" || t.tagName === "AUDIO")) { fromElement(t, type); }
        }, true);
    });

    // ---- 4. Resource Timing ----
    try {
        if (window.PerformanceObserver) {
            new PerformanceObserver(function (list) {
                var entries = list.getEntries();
                for (var i = 0; i < entries.length; i++) {
                    if (MEDIA_URL.test(entries[i].name)) { report(entries[i].name, { via: "timing" }); }
                }
            }).observe({ type: "resource", buffered: true });
        }
    } catch (e) {}
})();
