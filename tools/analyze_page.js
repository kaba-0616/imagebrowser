// (ImageSaver の tools/analyze_page.js を ImageCollector.js 用にしたもの)
// 実ページのHTMLを ImageCollector.js に通して、何が残り何が外れるかをリンク先
// ごとに数える。
//
//     curl -sL -A "Mozilla/5.0 (iPhone)" "<URL>" -o page.html
//     node tools/analyze_page.js page.html "<URL>"
//
// **抽出ルールを変えるときは、これを先に通す。** dryrun.js の手書きDOMは
// 「この条件でこう分類される」ことしか確かめられず、「実際のページの
// どのセクションが残るか」は分からない。2026-10-21、natalie.mu の
// おすすめ記事を隠す作業で、実ページを見ずに基準をいじって2回続けて
// 外した(400px固定の門番が iPhone の画面幅に届かず判定ごと無効 →
// 大きさの上限でランキングだけ取り残される)。実HTMLを通していれば
// どちらも最初の1回で分かった。
//
// 注意: レイアウトは無いので、幅は width/height 属性と imwidth/width
// クエリからの推定になる。**描画幅そのものは分からない**(natalie では
// 属性400の枠が小さく描かれ、属性216の枠が大きく描かれていた)。
// 大きさに依存する判定の検証には使えない。リンク構造の確認に使う。

const fs = require("fs"), vm = require("vm"), path = require("path");
const COLLECTOR = path.join(__dirname, "..", "ImageBrowserApp", "ImageExtraction", "ImageCollector.js");
const html = fs.readFileSync(process.argv[2], "utf8");
const pageURL = process.argv[3];

// <a href> の入れ子を追いながら <img> を拾う。
const els = [];
const tagRe = /<(\/?)(a|img)\b([^>]*)>/gi;
let m, stack = [];
function attrs(s) {
    const o = {};
    for (const a of s.matchAll(/([a-zA-Z_:][-a-zA-Z0-9_:.]*)\s*=\s*"([^"]*)"/g)) {
        o[a[1].toLowerCase()] = a[2].replace(/&amp;/g, "&");
    }
    return o;
}
function guessWidth(a) {
    if (a.width && /^\d+$/.test(a.width)) { return parseInt(a.width, 10); }
    const src = a.src || a["data-src"] || "";
    let q = /[?&]imwidth=(\d+)/.exec(src) || /[?&]width=(\d+)/.exec(src);
    return q ? parseInt(q[1], 10) : 0;
}
// 祖先の class も拾う(「おすすめ」「無限スクロールで継ぎ足された記事」は
// リンクではなく囲みの名前でしか分からないことがある)。
//
// 入れ子を正確に追うのは諦めて、**直前に開かれた囲みの class を数個**
// 拾う近似にしてある。閉じ忘れや void 要素で深さ追跡がすぐ壊れるため。
// 祖先でないものを拾うことがあるので、ここでの結果は目安。最終的な確認は
// 実機のログ(「おすすめ記事・ランキングの除外」の件数)で行う。
const boxRe = /<(div|section|article|aside|ul|ol|li|nav|footer)\b([^>]*)>/gi;
const boxes = [...html.matchAll(boxRe)].map(x => ({ i: x.index, box: attrs(x[2]) }));
function classesAt(index) {
    const out = [];
    for (let k = boxes.length - 1; k >= 0 && out.length < 8; k--) {
        if (boxes[k].i >= index) { continue; }
        const b = boxes[k].box;
        if (b["class"] || b["data-url"]) { out.push(b); }
    }
    return out;
}

while ((m = tagRe.exec(html))) {
    const closing = m[1] === "/", tag = m[2].toLowerCase(), a = attrs(m[3]);
    if (tag === "a") {
        // href の無い <a>(アンカー名だけのもの)でも必ず1つ積む。
        // 開いたものだけ積んで閉じるたびに捨てると、href 無しの <a> が
        // 1つあるだけで**本物の祖先リンクが落ちる**。xtrend.nikkei.com は
        // これで27枚すべてが「リンクなし」になり、別記事へのリンクの
        // 判定が丸ごと効いていないのに気づけなかった(2026-10-29)。
        if (closing) { stack.pop(); } else { stack.push(a.href || null); }
        continue;
    }
    if (closing) { continue; }
    a.__classes = classesAt(m.index);
    const w = guessWidth(a);
    const h = a.height && /^\d+$/.test(a.height) ? parseInt(a.height, 10) : w;
    let link = null;
    for (let k = stack.length - 1; k >= 0; k--) { if (stack[k]) { link = stack[k]; break; } }
    els.push({ a, link, w, h });
}

function El(e) {
    return {
        tag: "img", attrs: e.a, bg: "",
        rect: { width: e.w, height: e.h },
        naturalWidth: e.w, naturalHeight: e.h,
        currentSrc: e.a.src || "", src: e.a.src || "",
        shadowRoot: null,
        getAttribute(n) { return n in this.attrs ? this.attrs[n] : null; },
        getBoundingClientRect() { return this.rect; },
        closest(sel) { return e.link && sel === "a[href]" ? { href: e.link } : null; },
        parentElement: (e.a.__classes || []).slice().reverse().reduce(
            (child, box) => ({ getAttribute: n => (n in box ? box[n] : null), parentElement: child }), null),
        querySelectorAll() { return []; }
    };
}
const nodes = els.map(El);
function matches(el, sel) {
    sel = sel.trim();
    if (sel === "*" || sel === "img") { return sel === "*" || el.tag === "img"; }
    const mm = /^([a-z]*)((\[[^\]]*\])*)$/i.exec(sel.split(/\s+/).pop());
    if (!mm) { return false; }
    if (mm[1] && mm[1] !== el.tag) { return false; }
    for (const c of mm[2].match(/\[[^\]]*\]/g) || []) {
        const kv = /^\[([a-z_-]+)(?:([~]?=)'([^']*)')?\]$/i.exec(c);
        if (!kv) { return false; }
        const v = el.attrs[kv[1]];
        if (v == null) { return false; }
        if (kv[2] === "=" && v !== kv[3]) { return false; }
    }
    return true;
}
const document = {
    location: new URL(pageURL), baseURI: pageURL, URL: pageURL, title: "analyze",
    documentElement: { outerHTML: html, innerHTML: html, clientWidth: 390 },
    addEventListener() {},
    querySelectorAll(sel) { return nodes.filter(n => sel.split(",").some(s => matches(n, s))); },
    querySelector(sel) { return this.querySelectorAll(sel)[0] || null; },
    getElementsByTagName(t) { return this.querySelectorAll(t); },
    createElement() { return { style: {}, setAttribute() {}, getAttribute() { return null; } }; }
};
const ctx = { document, URL, console, WeakMap, Promise,
              performance: { getEntriesByType: () => [], clearResourceTimings() {} }, getComputedStyle: () => ({ backgroundImage: "none" }),
              window: { getComputedStyle: () => ({ backgroundImage: "none" }) },
              setTimeout, clearTimeout, Date, Math, JSON, encodeURIComponent, decodeURIComponent };
ctx.window.document = document;
ctx.globalThis = ctx;
vm.createContext(ctx);
vm.runInContext(fs.readFileSync(COLLECTOR, "utf8"), ctx);
const images = JSON.parse(JSON.stringify(ctx.window.__ImageBrowserCollector.collect(true)));
console.log(ctx.window.__ImageBrowserCollector.collectNote());
// ImageSaver と同じ見出しで比べられるように、隠す理由を origin 相当に戻す。
for (const i of images) { if (i.excluded === "other") { i.origin = "other"; } }
console.log("合計", images.length, "件");
const byOrigin = {};
for (const i of images) { byOrigin[i.origin] = (byOrigin[i.origin] || 0) + 1; }
console.log("分類:", byOrigin);
console.log("\n--- dom のURL(末尾) ---"); for (const i of images.filter(i=>i.origin==="dom").slice(0,40)) console.log("  ", i.url.replace(/^https?:\/\/[^/]+/, "").slice(-60)); console.log("\n--- other の内訳 ---"); for (const i of images.filter(i=>i.origin==="other")) console.log("  ", i.url.split("/").slice(-2).join("/"), i.why ? "(" + i.why + ")" : ""); console.log("\n--- 既定で表示されるもの(origin=dom)のリンク先 ---");
const linkOf = new Map();
for (const e of els) { if (e.a.src) linkOf.set(e.a.src, e.link); if (e.a["data-src"]) linkOf.set(e.a["data-src"], e.link); }
const counts = {};
for (const i of images.filter(i => i.origin === "dom")) {
    const l = linkOf.get(i.rendered || i.url) || "(リンクなし)";
    const key = l === "(リンクなし)" ? l : new URL(l, pageURL).pathname.split("/").slice(0, 4).join("/");
    counts[key] = (counts[key] || 0) + 1;
}
for (const [k, v] of Object.entries(counts).sort((a, b) => b[1] - a[1])) { console.log(String(v).padStart(4), k); }
