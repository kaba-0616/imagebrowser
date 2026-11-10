#!/bin/sh
# MP3 変換の検証プログラムを作る(Mac 向け)。LAME を一時フォルダで静的ライブラリにし、
# アプリと同じ `import LameMP3` で読めるようにモジュールマップを置く。
set -e
cd "$(dirname "$0")"
LAME=../../ThirdParty/lame
W=$(mktemp -d)
for f in $LAME/libmp3lame/*.c; do
  clang -c -O2 -DHAVE_CONFIG_H -I$LAME/libmp3lame -I$LAME/include -Wno-everything "$f" -o "$W/$(basename "$f").o"
done
ar rcs "$W/liblame.a" "$W"/*.o
mkdir -p "$W/LameMP3"
cp $LAME/include/lame.h "$W/LameMP3/"
printf 'module LameMP3 {\n  header "lame.h"\n  link "lame"\n  export *\n}\n' > "$W/LameMP3/module.modulemap"
swiftc -O -parse-as-library -I "$W/LameMP3" -L "$W" -o mp3check mp3check.swift ../../ImageBrowserApp/Download/AudioConverter.swift
rm -rf "$W"
