// ImageCollector.js を疑似DOM上で走らせ、実機ビルド無しにロジックを検証する。
// ImageSaverのtools/dryrun.jsと同じ手法(vmモジュール + 簡易DOM)を踏襲。
//
//     node tools/dryrun.js
//
// completionFunctionを介したコールバックは無く、collect()が同期的に配列を
// 返すだけなので、Action.js版よりモックは単純になっている。

const fs = require("fs"), vm = require("vm"), path = require("path");

const COLLECTOR = path.join(__dirname, "..", "ImageBrowserApp", "ImageExtraction", "ImageCollector.js");

function El(tag, attrs = {}, opts = {}) {
    return {
        tag, tagName: tag.toUpperCase(), attrs,
        bg: opts.bg || "",
        rect: opts.rect || { width: 200, height: 140 },
        naturalWidth: opts.nw || 0, naturalHeight: opts.nh || 0,
        currentSrc: attrs.src || "", src: attrs.src || "",
        shadowRoot: null,
        parentElement: null,
        getAttribute(n) { return n in this.attrs ? this.attrs[n] : null; },
        getBoundingClientRect() { return this.rect; },
        querySelectorAll() { return []; }
    };
}

function matches(el, sel) {
    sel = sel.trim();
    if (sel === "*") { return true; }
    const parts = sel.split(/\s+/);
    const m = /^([a-z]*)((\[[^\]]*\])*)$/i.exec(parts[parts.length - 1]);
    if (!m) { return false; }
    if (m[1] && m[1] !== el.tag) { return false; }
    for (const c of m[2].match(/\[[^\]]*\]/g) || []) {
        const kv = /^\[([a-z_-]+)(?:([~]?=)'([^']*)')?\]$/i.exec(c);
        if (!kv) { return false; }
        const v = el.attrs[kv[1]];
        if (v == null) { return false; }
        if (kv[2] === "=" && v !== kv[3]) { return false; }
        if (kv[2] === "~=" && !String(v).split(/\s+/).includes(kv[3])) { return false; }
    }
    return true;
}

function run(pageURL, els, opts = {}) {
    const document = {
        location: new URL(pageURL), baseURI: pageURL, URL: pageURL, title: "dry run",
        documentElement: { innerHTML: "<html></html>" },
        querySelectorAll(sel) {
            return els.filter(e => sel.split(",").some(s => matches(e, s)));
        },
        elementFromPoint(x, y) {
            return opts.elementAt ? opts.elementAt(x, y) : null;
        }
    };
    const ctx = {
        document, URL, console,
        getComputedStyle: (el) => ({ backgroundImage: el.bg || "none" })
    };
    ctx.window = ctx;
    vm.createContext(ctx);
    vm.runInContext(fs.readFileSync(COLLECTOR, "utf8"), ctx);
    return ctx.__ImageBrowserCollector;
}

let failures = 0;
function check(label, ok, detail = "") {
    console.log((ok ? "  ok   " : "  FAIL ") + label + (detail ? "  -- " + detail : ""));
    if (!ok) { failures++; }
}

function checkJSONSafe(images) {
    // JSON.stringifyはNaN/undefinedをnull化・省略するだけで例外は出さないが、
    // Swift側のデコードはurl/widthの型を前提にしているので、ここでは単純に
    // 「文字列化して再パースしても壊れない」ことだけ確認する。
    let ok = true;
    try {
        JSON.parse(JSON.stringify(images));
    } catch (e) {
        ok = false;
    }
    check("JSONとして安全", ok);
}

// ---------------------------------------------------------------------------
// リサイズ配信ページ: 縮小指定が外れ、同じ写真の複数サイズが1件に畳まれる。
// ---------------------------------------------------------------------------
{
    const H = "https://sakurazaka46.com/images/14";
    const els = [
        El("img", { src: "https://sakurazaka46.com/files/14/s46/img/logo.svg" }, { nw: 120, nh: 30 }),
        El("div", {}, { bg: `url("${H}/18d/f6c04bd71dbe206e6b322eca7576c/750_750_102400.jpg")` }),
        El("div", {}, { bg: `url("${H}/a8f/5788a167390678252e346a70e89df/300_300_102400.jpg")` }),
        El("div", {}, { bg: `url("${H}/a8f/5788a167390678252e346a70e89df/750_750_102400.jpg")` }),
        El("i", {}, { bg: `url("${H}/ccf/7167e7a550f4f7abd2f5329fe94d2/60_60_102400.jpg")`,
                      rect: { width: 24, height: 24 } })
    ];
    const collector = run("https://sakurazaka46.com/s/s46/contents_list?cd=104", els);
    const images = collector.collect(true);
    console.log("リサイズ配信のページ: " + images.length + "件");
    checkJSONSafe(images);

    const byURL = Object.fromEntries(images.map(i => [i.url, i]));
    check("縮小指定が外れている", !!byURL[`${H}/18d/f6c04bd71dbe206e6b322eca7576c.jpg`]);
    check("同じ写真の2サイズが1件に畳まれる",
          images.filter(i => i.url.includes("5788a167")).length === 1);
    check("ロゴは書き換えない",
          !byURL["https://sakurazaka46.com/files/14/s46/img/logo.svg"].rendered);
    check("アイコン枠の背景画像(24x24)は除外される",
          !byURL[`${H}/ccf/7167e7a550f4f7abd2f5329fe94d2.jpg`]);
}

// ---------------------------------------------------------------------------
// リサイズ配信でないページ: URLを書き換えず、素直にimg/lazy属性を拾う。
// ---------------------------------------------------------------------------
{
    const els = [
        El("img", { src: "https://example.com/photo.jpg" }, { nw: 1600, nh: 900 }),
        El("img", { "data-src": "https://example.com/lazy.jpg" }, { nw: 0, nh: 0 }),
        El("img", { src: "https://example.com/a/1920_1080_50.jpg" }, { nw: 1920, nh: 1080 })
    ];
    const collector = run("https://example.com/gallery", els);
    const images = collector.collect(true);
    console.log("\nリサイズ配信でないページ: " + images.length + "件");
    checkJSONSafe(images);
    check("URLを書き換えない", images.every(i => !i.rendered),
          images.filter(i => i.rendered).map(i => i.url).join(", "));
    check("lazy属性(data-src)も拾う",
          images.some(i => i.url === "https://example.com/lazy.jpg"));
    check("画像は3件取れている", images.length === 3, String(images.length));
}

// ---------------------------------------------------------------------------
// findImageAt: 長押し座標からimg要素のURLを引ける。
// ---------------------------------------------------------------------------
{
    const target = El("img", { src: "https://example.com/hit.jpg" }, { nw: 400, nh: 300 });
    const collector = run("https://example.com/page", [], {
        elementAt: (x, y) => (x === 50 && y === 60) ? target : null
    });
    const hit = collector.findImageAt(50, 60);
    const miss = collector.findImageAt(0, 0);
    console.log("\nfindImageAt:");
    check("座標が一致すればURLを返す", hit === "https://example.com/hit.jpg", String(hit));
    check("要素が無ければnullを返す", miss === null, String(miss));
}

console.log(failures ? `\n${failures}件 失敗` : "\nすべて通過");
process.exit(failures ? 1 : 0);
