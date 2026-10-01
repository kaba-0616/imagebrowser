// 通信の中身を調べる診断用スクリプト(document開始時に注入)。
//
// Flutter製のさくら坂46メッセージでは、タイムライン一覧は縮小版
// (/messages/thumbnails/)しか読み込まず、フルサイズ(/messages/files/)は
// 写真を個別に開いたときにしか取得されない。ただ、タイムラインの
// メッセージ一覧を取得するAPIの応答(JSON等)に、フルサイズの署名付きURLが
// 最初から含まれている可能性がある。それを確かめるため、ページが行う
// fetch/XMLHttpRequestの応答を横から読み、含まれる画像URLの件数と種類を
// アプリ本体(webkit.messageHandlers.imageBrowserNet)へ報告する。
//
// ページの動作は一切変えない: 元の関数をそのまま呼び、応答はclone()した
// 写しか、読み込み完了後の値を読むだけ。失敗はすべて握りつぶす。
(function () {
    "use strict";
    if (window.__ImageBrowserNetTap) { return; }
    window.__ImageBrowserNetTap = true;

    var IMAGE_URL = /https?:\/\/[^"'\s<>\\]+?\.(?:jpe?g|png|gif|webp)(?:\?[^"'\s<>\\]*)?/gi;
    // 画像・フォント・スクリプト等そのものの取得は対象外(APIの応答だけ見たい)。
    var SKIP_TYPE = /^(image|font|audio|video)\/|javascript|wasm|text\/css/i;
    var TEXT_TYPE = /json|text\/|xml/i;

    function post(payload) {
        try { window.webkit.messageHandlers.imageBrowserNet.postMessage(payload); } catch (e) {}
    }

    function report(reqURL, status, ctype, text, byteHint) {
        try {
            var images = [];
            if (text) {
                var t = text.length > 3000000 ? text.slice(0, 3000000) : text;
                // JSON内では "\/" や "&" にエスケープされていることがある。
                t = t.replace(/\\\//g, "/").replace(/\\u0026/gi, "&");
                var found = t.match(IMAGE_URL) || [];
                var seen = {};
                for (var i = 0; i < found.length; i++) {
                    if (!seen[found[i]]) { seen[found[i]] = 1; images.push(found[i]); }
                }
            }
            post({
                url: String(reqURL || ""),
                status: status | 0,
                ctype: String(ctype || ""),
                bytes: text ? text.length : (byteHint | 0),
                total: images.length,
                images: images.slice(0, 200)
            });
        } catch (e) {}
    }

    var originalFetch = window.fetch;
    if (originalFetch) {
        window.fetch = function (input) {
            var promise = originalFetch.apply(this, arguments);
            try {
                var reqURL = (input && input.url) || input;
                promise.then(function (res) {
                    try {
                        var ctype = res.headers.get("content-type") || "";
                        if (SKIP_TYPE.test(ctype)) { return; }
                        if (!TEXT_TYPE.test(ctype)) {
                            report(reqURL, res.status, ctype, null, res.headers.get("content-length"));
                            return;
                        }
                        res.clone().text().then(function (text) {
                            report(reqURL, res.status, ctype, text);
                        }, function () {});
                    } catch (e) {}
                }, function () {});
            } catch (e) {}
            return promise;
        };
    }

    var originalOpen = XMLHttpRequest.prototype.open;
    var originalSend = XMLHttpRequest.prototype.send;
    XMLHttpRequest.prototype.open = function (method, url) {
        this.__ibURL = url;
        return originalOpen.apply(this, arguments);
    };
    XMLHttpRequest.prototype.send = function () {
        var xhr = this;
        try {
            xhr.addEventListener("load", function () {
                try {
                    var ctype = xhr.getResponseHeader("content-type") || "";
                    if (SKIP_TYPE.test(ctype)) { return; }
                    if (!TEXT_TYPE.test(ctype)) {
                        var size = xhr.response && xhr.response.byteLength;
                        report(xhr.__ibURL, xhr.status, ctype, null, size);
                        return;
                    }
                    var type = xhr.responseType;
                    if (type === "" || type === "text") {
                        report(xhr.__ibURL, xhr.status, ctype, xhr.responseText);
                    } else if (type === "json") {
                        report(xhr.__ibURL, xhr.status, ctype, JSON.stringify(xhr.response));
                    } else if (type === "arraybuffer" && xhr.response) {
                        // Flutterのhttpパッケージ(BrowserClient)はarraybufferで受け取る。
                        report(xhr.__ibURL, xhr.status, ctype, new TextDecoder("utf-8").decode(xhr.response));
                    } else if (type === "blob" && xhr.response) {
                        xhr.response.text().then(function (text) {
                            report(xhr.__ibURL, xhr.status, ctype, text);
                        }, function () {});
                    }
                } catch (e) {}
            });
        } catch (e) {}
        return originalSend.apply(this, arguments);
    };
})();
