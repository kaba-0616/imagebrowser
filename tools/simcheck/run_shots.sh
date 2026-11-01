#!/bin/zsh
# ストア用の元画像を撮る: ./run_shots.sh <シミュレータのUDID> <出力先>
set -e
DEV=$1; OUT=$2
xcrun simctl status_bar $DEV override --time "9:41" --dataNetwork wifi --wifiBars 3 --cellularBars 4 --batteryState charged --batteryLevel 100
# 前回の入力やタブが残らないよう入れ直す。
xcrun simctl uninstall $DEV jp.kaba.imagebrowser || true
xcrun simctl install $DEV ../../build/sim/Build/Products/Debug-iphonesimulator/ImageBrowser*.app
xcodegen generate >/dev/null
rm -rf result.xcresult att
xcodebuild test -scheme DriveUITests -only-testing:DriveUITests/StoreShotUITests \
  -destination "platform=iOS Simulator,id=$DEV" -resultBundlePath result.xcresult \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|TEST (SUCCEEDED|FAILED)|\*\* " | tail -5
xcrun xcresulttool export attachments --path result.xcresult --output-path att >/dev/null
mkdir -p "$OUT"
python3 - "$OUT" <<'PY'
import json,shutil,sys
for t in json.load(open('att/manifest.json')):
    for a in t.get('attachments',[]):
        n=a['suggestedHumanReadableName'].split('_0_')[0]
        if '.' not in a['exportedFileName'] or a['exportedFileName'].endswith('.mp4'): continue
        if '_0_' not in a['suggestedHumanReadableName']: continue
        e=a['exportedFileName'].rsplit('.',1)[1]
        shutil.copy('att/'+a['exportedFileName'], f"{sys.argv[1]}/{n}.{e}")
        print(n)
PY
