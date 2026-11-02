// メッセージ系サイトの効果音をマナーモードに従わせる(document開始時に注入)。
//
// message.sakurazaka46.com などの Flutter 製サイトは、トークを開く音や
// 着信音(assets/sound/*.mp3)を <audio> 要素で鳴らす。<audio> はマナーモードを
// 無視するので、効果音のときだけ Audio Session API を ambient にする。ボイスや
// 動画は操作して再生するものなので、これまで通りマナーモードでも鳴らす。
//
// 失敗しても再生そのものは止めない。効いたかどうかは「ログ」で確かめられる。
(function () {
    "use strict";
    if (window.__ImageBrowserSoundSession) { return; }
    window.__ImageBrowserSoundSession = true;
    if (!/^message\./.test(location.hostname)) { return; }

    var EFFECT = /\/assets\/sound\//;
    var reported = {};

    function report(src, effect) {
        var name = src.split("?")[0].split("/").pop();
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
