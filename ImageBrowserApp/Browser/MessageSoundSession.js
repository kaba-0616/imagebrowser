// メッセージ系サイトの効果音をマナーモードに従わせる(document開始時に注入)。
//
// message.sakurazaka46.com などの Flutter 製サイトは、トークを開く音や
// 着信音(assets/sound/*.mp3)を <audio> 要素で鳴らす。<audio> はマナーモードを
// 無視するので、効果音のときだけ Audio Session API を ambient にする。ボイスや
// 動画は操作して再生するものなので、これまで通りマナーモードでも鳴らす。
//
// 効果音はファイルの URL ではなく、中身を埋め込んだ data: で再生される
// (1.5.1(0.2) の実機ログで確認)。ボイスは CDN の URL なので data: で見分ける。
//
// 失敗しても再生そのものは止めない。効いたかどうかは「ログ」で確かめられる。
(function () {
    "use strict";
    if (window.__ImageBrowserSoundSession) { return; }
    window.__ImageBrowserSoundSession = true;
    if (!/^message\.|^service\.yodel-app\.com$/.test(location.hostname)) { return; }

    var EFFECT = /^data:|\/assets\/sound\//;
    var reported = {};

    function report(src, effect) {
        var name = /^data:/.test(src)
            ? src.slice(0, src.indexOf(",")) + " " + src.length + "文字"
            : src.split("?")[0].split("/").pop();
        if (reported[name]) { return; }
        reported[name] = true;
        try {
            window.webkit.messageHandlers.imageBrowserNet.postMessage({
                kind: "sound",
                name: name,
                effect: effect,
                session: navigator.audioSession ? navigator.audioSession.type : "なし"
            });
        } catch (e) {}
    }

    var play = HTMLMediaElement.prototype.play;
    HTMLMediaElement.prototype.play = function () {
        try {
            var src = this.currentSrc || this.src || "";
            var effect = EFFECT.test(src);
            if (navigator.audioSession) {
                navigator.audioSession.type = effect ? "ambient" : "auto";
            }
            report(src, effect);
        } catch (e) {}
        return play.apply(this, arguments);
    };
})();
