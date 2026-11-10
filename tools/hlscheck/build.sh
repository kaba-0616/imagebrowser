#!/bin/sh
# HLS 変換の検証プログラムを作る(Mac 向け)。
cd "$(dirname "$0")" && swiftc -O -parse-as-library -o hlscheck main.swift ../../ImageBrowserApp/Download/HLSPlaylist.swift ../../ImageBrowserApp/Download/TSDemuxer.swift ../../ImageBrowserApp/Download/TSToMP4Writer.swift ../../ImageBrowserApp/Download/HLSDownloader.swift 2>&1
