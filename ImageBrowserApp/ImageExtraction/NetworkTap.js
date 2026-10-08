// 通信の中身を調べる診断用スクリプト(document開始時に注入)。
//
// Flutter製の櫻坂46メッセージでは、タイムライン一覧は縮小版
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

    // ページ自身がAPI呼び出しに付けている認証系ヘッダー(Authorization と
    // x-で始まるもの)を、送信先オリジンごとにメモリ上でだけ憶えておく。
    // 期限切れ署名URLの差し替え(__ImageBrowserRefreshMessageImages)で、
    // ページと同じ権限のままAPIを呼び直すため。値はログにも外にも出さない。
    var authHeadersByOrigin = {};
    function rememberHeader(url, name, value) {
        try {
            if (!/^authorization$|^x-/i.test(String(name))) { return; }
            var origin = new URL(String(url), location.href).origin;
            (authHeadersByOrigin[origin] = authHeadersByOrigin[origin] || {})[name] = value;
        } catch (e) {}
    }
    function rememberFetchHeaders(url, headers) {
        try {
            if (!headers) { return; }
            if (typeof headers.forEach === "function" && !Array.isArray(headers)) {
                headers.forEach(function (value, name) { rememberHeader(url, name, value); });
            } else if (Array.isArray(headers)) {
                headers.forEach(function (pair) { rememberHeader(url, pair[0], pair[1]); });
            } else {
                Object.keys(headers).forEach(function (name) { rememberHeader(url, name, headers[name]); });
            }
        } catch (e) {}
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
                        var fileURLs = {};
                        var cursorReq = tx.objectStore(storeName).openCursor();
                        cursorReq.onsuccess = function () {
                            var cursor = cursorReq.result;
                            if (cursor && records < 20000) {
                                records++;
                                // Flutter(SQLite on IndexedDB等)はバイナリで保存する。
                                // URLはASCIIなので、UTF-8として読めば文字列で見つかる。
                                var imgs = findImages(idbValueText(cursor.value));
                                total += imgs.length;
                                for (var j = 0; j < imgs.length; j++) {
                                    if (imgs[j].indexOf("/files/") !== -1) {
                                        files++;
                                        fileURLs[imgs[j]] = 1;
                                    }
                                }
                                cursor.continue();
                            } else {
                                // fileURLs: アプリ本体側で、一括抽出時に縮小版を
                                // フルサイズへ置き換えるための対応表として使う。
                                post({
                                    kind: "idb-store", db: name, store: storeName,
                                    records: records, total: total, files: files,
                                    fileURLs: Object.keys(fileURLs).slice(0, 5000)
                                });
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

    // IndexedDBの値を文字列化する(バイナリはUTF-8として読む)。
    function idbValueText(v) {
        try {
            if (typeof v === "string") { return v; }
            if (v instanceof ArrayBuffer || ArrayBuffer.isView(v)) { return new TextDecoder("utf-8").decode(v); }
            return JSON.stringify(v);
        } catch (e) {
            return "";
        }
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

    // 長押し保存の照合用: このページが開いてから読み込んだ画像URLを
    // すべて憶えておく(パスごとに最新の1件)。一括抽出側の通信履歴は
    // 読むたびに消化する(ImageCollector.jsのresourceTimingImages)ため、
    // アプリを開き直した直後や画面を切り替えた直後に長押しすると候補が
    // ほとんど残っていなかった(実機ログで候補3件、該当写真なし)。
    // PerformanceObserverはバッファの消去や上限の影響を受けずに届く。
    var seenImages = {};
    var SEEN_IMAGE = /\.(?:jpe?g|png|gif|webp)(?:\?|#|$)/i;
    var SEEN_SKIP = /\/favicon\.[a-z]+(\?|#|$)|\/icons\/Icon-(maskable-)?\d+\.png|\/(members|groups|users)\/(thumbnails|phone-images)\/|\/app_configs\/|\/splash\/img\//i;
    try {
        new PerformanceObserver(function (list) {
            try {
                var entries = list.getEntries();
                for (var i = 0; i < entries.length; i++) {
                    var url = entries[i].name;
                    if (!SEEN_IMAGE.test(url) || SEEN_SKIP.test(url)) { continue; }
                    var key = url.split("?")[0];
                    delete seenImages[key];
                    seenImages[key] = url;
                }
            } catch (e) {}
        }).observe({ type: "resource", buffered: true });
    } catch (e) {}
    // 古い順。末尾ほど最近読み込まれたもの。
    window.__ImageBrowserSeenImages = function () {
        var keys = Object.keys(seenImages);
        var out = [];
        for (var i = Math.max(0, keys.length - 3000); i < keys.length; i++) { out.push(seenImages[keys[i]]); }
        return out;
    };

    var originalFetch = window.fetch;
    if (originalFetch) {
        window.fetch = function (input, init) {
            try {
                var headerURL = (input && input.url) || input;
                if (input && input.headers) { rememberFetchHeaders(headerURL, input.headers); }
                if (init && init.headers) { rememberFetchHeaders(headerURL, init.headers); }
            } catch (e) {}
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
    var originalSetRequestHeader = XMLHttpRequest.prototype.setRequestHeader;
    XMLHttpRequest.prototype.setRequestHeader = function (name, value) {
        rememberHeader(this.__ibURL, name, value);
        return originalSetRequestHeader.apply(this, arguments);
    };

    // 一括抽出用: メッセージ番号ごとに /v2/messages/<番号> をページと同じ
    // 認証ヘッダーで呼び直し、その場で署名された最新の画像URLを集めて
    // アプリ本体へ返す(kind: "refresh")。櫻坂46メッセージは過去
    // メッセージの署名付きURLを端末内に何日もキャッシュしていて、それらは
    // 期限切れのためアプリから取得すると403になる。ページ側はブラウザの
    // キャッシュで表示できているだけ。同時実行は4件まで。
    window.__ImageBrowserRefreshMessageImages = function (requestID, apiOrigin, ids) {
        var headers = authHeadersByOrigin[apiOrigin] || {};
        var results = {};
        var statuses = {};
        var index = 0, active = 0, finished = false;
        function finish() {
            if (finished) { return; }
            finished = true;
            post({ kind: "refresh", requestID: requestID, results: results, statuses: statuses, headerNames: Object.keys(headers) });
        }
        function next() {
            if (index >= ids.length && active === 0) { finish(); return; }
            while (active < 4 && index < ids.length) {
                (function (id) {
                    active++;
                    originalFetch.call(window, apiOrigin + "/v2/messages/" + encodeURIComponent(id), { headers: headers, credentials: "include" })
                        .then(function (res) {
                            statuses[res.status] = (statuses[res.status] || 0) + 1;
                            return res.status === 200 ? res.text() : "";
                        })
                        .then(function (text) {
                            // type/本体ファイルの拡張子も返す: 動画メッセージの
                            // サムネイル(ポスター画像)を抽出対象から外すため。
                            var type = "", ext = "";
                            try {
                                var json = JSON.parse(text);
                                type = String(json.type || "");
                                var m = /\.([a-z0-9]+)(?:\?|#|$)/i.exec(String(json.file || ""));
                                ext = m ? m[1].toLowerCase() : "";
                            } catch (e) {}
                            results[id] = { images: findImages(text), type: type, ext: ext };
                        }, function () {
                            statuses.error = (statuses.error || 0) + 1;
                            results[id] = { images: [], type: "", ext: "" };
                        })
                        .then(function () { active--; next(); });
                })(ids[index++]);
            }
        }
        if (!originalFetch || !ids || !ids.length) { finish(); return; }
        next();
    };
    // 長押し保存の照合用: トーク(グループ)のメッセージ一覧を、ページと同じ
    // タイムラインAPI(/v2/groups/<番号>/timeline)で最初から全部たどって
    // アプリ本体へ返す(kind: "timeline")。ページ自身は前回からの差分しか
    // 取らず、写真もほぼ端末内のキャッシュから描くため、読み込み記録からは
    // 画面に出ている写真の候補がほとんど集まらなかった(実機ログで3件)。
    // ページが付けているclear_unread(既読にする指定)は付けない。
    // 1回200件、最大30回まで。メッセージ本文は返さない。
    window.__ImageBrowserFetchTimeline = function (requestID, apiOrigin, groupID) {
        var headers = authHeadersByOrigin[apiOrigin] || {};
        var messages = [];
        var keys = {};
        var pages = 0, status = 0;
        // Network failures are retried until the walk completes (user
        // request: don't stop half way), but not forever when offline.
        var deadline = Date.now() + 180000;
        function finish(error) {
            post({
                kind: "timeline", requestID: requestID, groupID: String(groupID), messages: messages,
                pages: pages, status: status, keys: Object.keys(keys), error: error || "",
                fromTimeline: fromTimeline, fromPast: fromPast
            });
        }
        function text(v) { return v === undefined || v === null ? "" : String(v); }
        var fromTimeline = 0, fromPast = 0;
        function add(list) {
            for (var i = 0; i < list.length; i++) {
                var m = list[i] || {};
                for (var k in m) { keys[k] = 1; }
                messages.push({
                    id: text(m.id), type: text(m.type), file: text(m.file), thumbnail: text(m.thumbnail),
                    width: m.thumbnail_width | 0, height: m.thumbnail_height | 0,
                    at: text(m.published_at)
                });
            }
            return list.length;
        }
        // GET with retry: a request can fail mid-walk (seen on device: "Load
        // failed" when the app went to the background); it's retried as is,
        // so the walk carries on from the same page. A non-200 is a refusal
        // (expired login...) that retrying won't fix.
        function get(url, onJSON, attempt) {
            attempt = attempt || 0;
            originalFetch.call(window, url, { headers: headers, credentials: "include" })
                .then(function (res) {
                    status = res.status;
                    return res.status === 200 ? res.json() : null;
                })
                .then(function (json) {
                    if (status !== 200) { finish("HTTP " + status + " " + url.split("?")[0].split("/").pop()); return; }
                    onJSON(json || {});
                }, function (e) {
                    if (Date.now() < deadline) {
                        setTimeout(function () { get(url, onJSON, attempt + 1); }, Math.min(5000, 1000 * (attempt + 1)));
                    } else {
                        finish(String(e) + " (再試行" + attempt + "回)");
                    }
                });
        }
        var base = apiOrigin + "/v2/groups/" + encodeURIComponent(groupID);
        // The same walk the site's own timeline does: newest first, then
        // follow `continuation` back to the start. The updated_from/asc
        // query used before returned only part of a talk (588 messages
        // where the site's own photo list showed far more).
        function page(continuation) {
            var url = base + "/timeline?" + (continuation
                ? "continuation=" + encodeURIComponent(continuation)
                : "count=200&order=desc");
            get(url, function (json) {
                pages++;
                fromTimeline += add(json.messages || []);
                // 進み具合(読んだ件数だけ)。数千件のトークでは30秒以上かかるため。
                post({ kind: "timelineProgress", groupID: String(groupID), messages: messages.length, pages: pages });
                if (json.continuation && pages < 200) { page(json.continuation); return; }
                past();
            });
        }
        // Messages the site lists separately as "past" ones.
        function past() {
            get(base + "/past_messages", function (json) {
                fromPast += add(json.messages || []);
                finish();
            });
        }
        if (!originalFetch) { finish("fetch unavailable"); return; }
        page("");
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
