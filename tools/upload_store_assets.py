#!/usr/bin/env python3
"""ストア用の画像を App Store Connect へ上げる。

- プロダクトページのヘッダ / 検索結果 … appAssetLibrary(スクショとは別系統)
- iPhone Duo のスクリーンショット    … appScreenshotSets(APP_IPHONE_DUO)

手順と罠は imagesaver-safari/ストア用/プロダクトページ/README.md。ヘッダは
5244x2950、PNG はアルファ無し。**処理が終わる前に placement は作れない。**

    python3 -I tools/upload_store_assets.py <アプリID> <ローカリゼーションID>
    python3 -I tools/upload_store_assets.py <アプリID> <ローカリゼーションID> header  # ヘッダだけ差し替える

asc.py(JWT で API を叩く)は oshicount/tools にある。
"""
import hashlib, os, sys, time, urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(os.path.dirname(ROOT), "oshicount", "tools"))
from asc import call

APP, LOC = sys.argv[1], sys.argv[2]
STORE = os.path.join(ROOT, "ストア掲載用")
CREATIVE = [("プロダクトページ/header-5244x2950.png", "PRODUCT_PAGE_HEADER_ASSET"),
            ("プロダクトページ/search-1920x1280.png", "APP_STORE_SEARCH_RESULTS_ASSET")]
DUO = ["Duo/Duo_IB_1.png", "Duo/Duo_IB_2.png", "Duo/Duo_IB_3.png"]


def api(method, path, body=None):
    st, j = call(method, path, body)
    if st >= 300:
        raise SystemExit(f"{method} {path} -> {st} {str(j)[:600]}")
    return j


def put_chunks(path, ops):
    blob = open(path, "rb").read()
    for op in ops:
        req = urllib.request.Request(op["url"], method=op["method"],
                                     data=blob[op["offset"]:op["offset"] + op["length"]])
        for h in op["requestHeaders"]:
            req.add_header(h["name"], h["value"])
        urllib.request.urlopen(req).read()


def upload_creative(rel, placement):
    path = os.path.join(STORE, rel)
    r = api("POST", "/v1/appAssetLibraryImages", {"data": {
        "type": "appAssetLibraryImages",
        "attributes": {"fileName": os.path.basename(path), "fileSize": os.path.getsize(path),
                       "category": "CREATIVE_ASSETS"},
        "relationships": {"assetLibrary": {"data": {"type": "appAssetLibraries", "id": APP}}}}})["data"]
    iid = r["id"]
    put_chunks(path, r["attributes"]["uploadOperations"])
    api("PATCH", f"/v1/appAssetLibraryImages/{iid}", {"data": {
        "type": "appAssetLibraryImages", "id": iid, "attributes": {"uploaded": True}}})
    for _ in range(40):
        a = api("GET", f"/v1/appAssetLibraryImages/{iid}")["data"]["attributes"]
        if a["state"] == "FAILED":
            raise SystemExit(f"{rel}: {a.get('stateDetails')}")
        if a["state"] not in ("AWAITING_UPLOAD", "UPLOAD_COMPLETE", "PROCESSING"):
            break
        time.sleep(15)
    p = api("POST", "/v1/appAssetLibraryPlacements", {"data": {
        "type": "appAssetLibraryPlacements", "attributes": {"placementType": placement},
        "relationships": {
            "image": {"data": {"type": "appAssetLibraryImages", "id": iid}},
            "appStoreVersionLocalization": {"data": {"type": "appStoreVersionLocalizations", "id": LOC}}}}})["data"]
    print(rel, a["state"], p["attributes"]["state"])


def replace_header():
    """差し替えは先に placement を消す(残っていると 409)。"""
    rel, placement = CREATIVE[0]
    for p in api("GET", f"/v1/appStoreVersionLocalizations/{LOC}/placements?limit=50")["data"]:
        if p["attributes"]["placementType"] == placement:
            api("DELETE", f"/v1/appAssetLibraryPlacements/{p['id']}")
    upload_creative(rel, placement)


def upload_duo():
    sets = api("GET", f"/v1/appStoreVersionLocalizations/{LOC}/appScreenshotSets?limit=20")["data"]
    sid = next((s["id"] for s in sets if s["attributes"]["screenshotDisplayType"] == "APP_IPHONE_DUO"), None)
    if not sid:
        sid = api("POST", "/v1/appScreenshotSets", {"data": {
            "type": "appScreenshotSets", "attributes": {"screenshotDisplayType": "APP_IPHONE_DUO"},
            "relationships": {"appStoreVersionLocalization": {"data": {
                "type": "appStoreVersionLocalizations", "id": LOC}}}}})["data"]["id"]
    for rel in DUO:
        path = os.path.join(STORE, rel)
        r = api("POST", "/v1/appScreenshots", {"data": {
            "type": "appScreenshots",
            "attributes": {"fileName": os.path.basename(path), "fileSize": os.path.getsize(path)},
            "relationships": {"appScreenshotSet": {"data": {"type": "appScreenshotSets", "id": sid}}}}})["data"]
        put_chunks(path, r["attributes"]["uploadOperations"])
        md5 = hashlib.md5(open(path, "rb").read()).hexdigest()
        api("PATCH", f"/v1/appScreenshots/{r['id']}", {"data": {
            "type": "appScreenshots", "id": r["id"],
            "attributes": {"uploaded": True, "sourceFileChecksum": md5}}})
        print(rel, "uploaded")


if sys.argv[3:] == ["header"]:
    replace_header()
else:
    upload_duo()
    for rel, placement in CREATIVE:
        upload_creative(rel, placement)
