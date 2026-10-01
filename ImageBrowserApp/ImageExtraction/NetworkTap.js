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

    function findImages(text) {
        var images = [];
        if (!text) { return images; }
        var t = text.length > 3000000 ? text.slice(0, 3000000) : text;
        // JSON内では "\/" や "&" にエスケープされていることがある。
        t = t.replace(/\\\//g, "/").replace(/\\u0026/gi, "&");
        var found = t.match(IMAGE_URL) || [];
        var seen = {};
        for (var i = 0; i < found.length; i++) {
            if (!seen[found[i]]) { seen[found[i]] = 1; images.push(found[i]); }
        }
        return images;
    }

    // JSONの「形」だけを短い文字列にする(値は含めない。メッセージ本文等の
    // 中身をログに残さないため)。例: {messages:array(1){id,file,thumbnail}}
    function describeShape(text) {
        try {
            var v = JSON.parse(text);
            function one(x, depth) {
                if (Array.isArray(x)) {
                    return "array(" + x.length + ")" + (x.length && depth < 2 ? one(x[0], depth + 1) : "");
                }
                if (x && typeof x === "object") {
                    var keys = Object.keys(x);
                    var parts = [];
                    for (var i = 0; i < keys.length && i < 20; i++) {
                        var c = x[keys[i]];
                        if (depth < 1 && (Array.isArray(c) || (c && typeof c === "object"))) {
                            parts.push(keys[i] + ":" + one(c, depth + 1));
                        } else {
                            parts.push(keys[i]);
                        }
                    }
                    return "{" + parts.join(",") + (keys.length > 20 ? ",…" : "") + "}";
                }
                return typeof x;
            }
            return one(v, 0).slice(0, 400);
        } catch (e) {
            return "";
        }
    }

    function report(reqURL, status, ctype, text, byteHint) {
        try {
            var images = findImages(text);
            post({
                kind: "api",
                url: String(reqURL || ""),
                status: status | 0,
                ctype: String(ctype || ""),
                bytes: text ? text.length : (byteHint | 0),
                shape: text && /json/i.test(ctype) ? describeShape(text) : "",
                total: images.length,
                images: images.slice(0, 200)
            });
        } catch (e) {}
    }

    // WebSocketで届くデータにも画像URLが含まれていないかを見る。
    // 接続時に1回、以降は画像URLを含むデータが届いたときだけ報告する。
    var OriginalWebSocket = window.WebSocket;
    if (OriginalWebSocket) {
        var WrappedWebSocket = function (url, protocols) {
            var ws = protocols === undefined ? new OriginalWebSocket(url) : new OriginalWebSocket(url, protocols);
            try {
                post({ kind: "ws-open", url: String(url) });
                ws.addEventListener("message", function (ev) {
                    try {
                        if (typeof ev.data !== "string") { return; }
                        var images = findImages(ev.data);
                        if (!images.length) { return; }
                        post({ kind: "ws", url: String(url), bytes: ev.data.length, total: images.length, images: images.slice(0, 200) });
                    } catch (e) {}
                });
            } catch (e) {}
            return ws;
        };
        WrappedWebSocket.prototype = OriginalWebSocket.prototype;
        WrappedWebSocket.CONNECTING = OriginalWebSocket.CONNECTING;
        WrappedWebSocket.OPEN = OriginalWebSocket.OPEN;
        WrappedWebSocket.CLOSING = OriginalWebSocket.CLOSING;
        WrappedWebSocket.CLOSED = OriginalWebSocket.CLOSED;
        window.WebSocket = WrappedWebSocket;
    }

    // IndexedDBの各ストアを読み取り専用で走査し、画像URLの件数を数える。
    // バージョンを指定せずに開くので、DBの構造を変える(upgrade)ことはない。
    function scanDatabase(name) {
        try {
            var req = indexedDB.open(name);
            req.onsuccess = function () {
                var db = req.result;
                try {
                    var storeNames = Array.prototype.slice.call(db.objectStoreNames);
                    if (!storeNames.length) { db.close(); return; }
                    var tx = db.transaction(storeNames, "readonly");
                    storeNames.forEach(function (storeName) {
                        var records = 0, total = 0, files = 0;
                        var cursorReq = tx.objectStore(storeName).openCursor();
                        cursorReq.onsuccess = function () {
                            var cursor = cursorReq.result;
                            if (cursor && records < 5000) {
                                records++;
                                var text = "";
                                try {
                                    var v = cursor.value;
                                    if (typeof v === "string") {
                                        text = v;
                                    } else if (v instanceof ArrayBuffer || ArrayBuffer.isView(v)) {
                                        // Flutter(Hive等)はバイナリで保存することがある。
                                        // URLはASCIIなので、UTF-8として読めば文字列で見つかる。
                                        text = new TextDecoder("utf-8").decode(v);
                                    } else {
                                        text = JSON.stringify(v);
                                    }
                                } catch (e) {}
                                var imgs = findImages(text);
                                total += imgs.length;
                                for (var j = 0; j < imgs.length; j++) {
                                    if (imgs[j].indexOf("/files/") !== -1) { files++; }
                                }
                                cursor.continue();
                            } else {
                                post({ kind: "idb-store", db: name, store: storeName, records: records, total: total, files: files });
                            }
                        };
                        cursorReq.onerror = function () {
                            post({ kind: "idb-store", db: name, store: storeName, error: "cursor error" });
                        };
                    });
                    tx.oncomplete = function () { db.close(); };
                } catch (e) {
                    post({ kind: "idb-store", db: name, error: String(e) });
                    try { db.close(); } catch (e2) {}
                }
            };
            req.onerror = function () { post({ kind: "idb-store", db: name, error: "open error" }); };
        } catch (e) {}
    }

    // 一括抽出のタイミングでアプリ本体から呼ばれる。端末内の保存領域
    // (localStorage/sessionStorage/IndexedDB)に画像URLがどれだけ入っているか
    // を報告する。キャッシュから過去メッセージを描いているかの切り分け用。
    window.__ImageBrowserStorageReport = function () {
        function scan(store, label) {
            try {
                var total = 0, files = 0, entries = 0, bytes = 0, sample = [];
                for (var i = 0; i < store.length; i++) {
                    var k = store.key(i);
                    var v = store.getItem(k) || "";
                    bytes += v.length;
                    var imgs = findImages(v);
                    if (imgs.length) {
                        entries++;
                        total += imgs.length;
                        for (var j = 0; j < imgs.length; j++) {
                            if (imgs[j].indexOf("/files/") !== -1) { files++; }
                        }
                        if (sample.length < 5) { sample.push(String(k).slice(0, 60) + "(" + imgs.length + ")"); }
                    }
                }
                post({ kind: "storage", store: label, keys: store.length, bytes: bytes, entries: entries, total: total, files: files, sample: sample });
            } catch (e) {
                post({ kind: "storage", store: label, error: String(e) });
            }
        }
        try { scan(window.localStorage, "localStorage"); } catch (e) {}
        try { scan(window.sessionStorage, "sessionStorage"); } catch (e) {}
        try {
            if (indexedDB && indexedDB.databases) {
                indexedDB.databases().then(function (dbs) {
                    var names = [];
                    for (var i = 0; i < dbs.length; i++) { names.push(dbs[i].name + "@v" + dbs[i].version); }
                    post({ kind: "idb", names: names });
                    for (var d = 0; d < dbs.length; d++) { scanDatabase(dbs[d].name); }
                }, function (e) { post({ kind: "idb", error: String(e) }); });
            }
        } catch (e) {}
    };

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
