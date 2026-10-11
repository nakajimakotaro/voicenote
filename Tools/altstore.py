#!/usr/bin/env python3
"""AltStore PAL での配布を受け持つ。

このリポジトリ（HOST_REPO、public）の Releases にすべて置く。
  - タグ source:              source.json とアイコン（毎回上書き）
  - タグ <bundleId>-<版>-<ビルド>: 公証済み ADP のファイル（Apple が作ったまま一切手を加えない）
元になる source.json は AltStore/source.json で、このリポジトリで管理する。

サブコマンド
  register     AltStore PAL に Developer ID を登録し、App Store Connect に入れるトークンをもらう
  permissions  アプリと拡張の entitlements と UsageDescription を source.json に書き出す
  validate     source.json に足りない項目がないか調べる
  push-source  source.json とアイコンを公開する
  publish      公証済みの ADP を取ってきて公開し、source.json に版を足して公開する
  federate     explore.alt.store で検索できるようにする（source.json に fediUsername が必要）

標準ライブラリだけで動く。push-source と publish には gh（ログイン済み）が要る。
"""

import argparse
import json
import plistlib
import re
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
import zipfile
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "AltStore" / "source.json"
ICON = ROOT / "VoiceNote" / "Resources" / "Assets.xcassets" / "AppIcon.appiconset" / "AppIcon.png"
HOST_REPO = "nakajimakotaro/voicenote"
SOURCE_TAG = "source"
API = "https://api.altstore.io"
PLACEHOLDER = "REPLACE_ME"
# AltStore が自分で足すもの、配布版の署名には入らないもの
IGNORED_ENTITLEMENTS = {"application-identifier", "com.apple.developer.team-identifier", "get-task-allow"}


def release_url(tag, name):
    return f"https://github.com/{HOST_REPO}/releases/download/{tag}/{name}"


SOURCE_URL = release_url(SOURCE_TAG, "source.json")


def load_source():
    return json.loads(SOURCE.read_text(encoding="utf-8"))


def save_source(src):
    SOURCE.write_text(json.dumps(src, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


# ---------------------------------------------------------------- AltStore API

def api(method, path, body=None):
    data = json.dumps(body).encode() if body is not None else None
    # Python 既定の User-Agent だと Cloudflare に 403（error code: 1010）で弾かれる
    req = urllib.request.Request(API + path, data=data, method=method,
                                 headers={"Content-Type": "application/json", "User-Agent": "curl/8.7.1"})
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            return resp.status, parse_json(resp.read())
    except urllib.error.HTTPError as e:
        return e.code, parse_json(e.read())


def parse_json(raw):
    try:
        return json.loads(raw) if raw else {}
    except ValueError:
        return {"raw": raw.decode(errors="replace")[:500]}


def cmd_register(args):
    status, resp = api("POST", "/register", {"developerID": args.developer_id, "email": args.email})
    print(f"HTTP {status}")
    print(json.dumps(resp, indent=2, ensure_ascii=False))
    if status >= 300 or "token" not in resp:
        sys.exit(1)
    print("\nApp Store Connect → ユーザとアクセス → 統合 → マーケットプレイス → ＋ に token を貼ってください")


def cmd_federate(_args):
    if not load_source().get("fediUsername"):
        sys.exit("source.json に fediUsername がありません（あとから変えられないので慎重に決める）")
    status, resp = api("POST", "/federate", {"source": SOURCE_URL})
    print(f"HTTP {status} {resp}")
    if status >= 300:
        sys.exit(1)


# ---------------------------------------------------------------- 権限

def find_app(path, tmp):
    """.app、.xcarchive、.ipa のどれを渡されても .app を返す"""
    path = Path(path)
    if path.suffix == ".app":
        return path
    if path.suffix == ".xcarchive":
        apps = list((path / "Products" / "Applications").glob("*.app"))
    elif path.suffix == ".ipa":
        with zipfile.ZipFile(path) as z:
            z.extractall(tmp)
        apps = list((Path(tmp) / "Payload").glob("*.app"))
    else:
        sys.exit(f"{path} は .app / .xcarchive / .ipa のどれでもありません")
    if len(apps) != 1:
        sys.exit(f"{path} の中にアプリが {len(apps)} 個あります")
    return apps[0]


def entitlements(bundle):
    out = subprocess.run(["codesign", "-d", "--entitlements", "-", "--xml", str(bundle)],
                         check=True, capture_output=True).stdout
    if not out.strip():
        sys.exit(f"{bundle} は署名されていません")
    return plistlib.loads(out)


def cmd_permissions(args):
    with tempfile.TemporaryDirectory() as tmp:
        app = find_app(args.path, tmp)
        bundles = [app, *sorted((app / "PlugIns").glob("*.appex"))]
        ents, privacy = set(), {}
        for bundle in bundles:
            ents |= entitlements(bundle).keys() - IGNORED_ENTITLEMENTS
            info = plistlib.loads((bundle / "Info.plist").read_bytes())
            privacy |= {k: v for k, v in info.items() if k.endswith("UsageDescription")}
        bundle_id = plistlib.loads((app / "Info.plist").read_bytes())["CFBundleIdentifier"]

    src = load_source()
    entry = find_source_app(src, bundle_id)
    entry["appPermissions"] = {"entitlements": sorted(ents), "privacy": privacy}
    save_source(src)
    print(f"{bundle_id} の権限を書き出しました: {sorted(ents)} {sorted(privacy)}")


def find_source_app(src, bundle_id):
    app = next((a for a in src["apps"] if a["bundleIdentifier"] == bundle_id), None)
    if app is None:
        sys.exit(f"source.json に {bundle_id} のアプリがありません")
    return app


# ---------------------------------------------------------------- source.json

def validate(src):
    errors = []
    if PLACEHOLDER in json.dumps(src, ensure_ascii=False):
        errors.append(f"{PLACEHOLDER} が残っています")
    for key in ("name", "apps"):
        if key not in src:
            errors.append(f"source: {key} がありません")
    for app in src.get("apps", []):
        label = app.get("bundleIdentifier", "?")
        for key in ("name", "bundleIdentifier", "marketplaceID", "developerName",
                    "localizedDescription", "iconURL", "versions", "appPermissions"):
            if key not in app:
                errors.append(f"{label}: {key} がありません")
        if not str(app.get("marketplaceID", "")).isdigit():
            errors.append(f"{label}: marketplaceID は App Store Connect の Apple ID（数字）です")
        for v in app.get("versions", []):
            for key in ("version", "buildVersion", "date", "downloadURL", "size"):
                if key not in v:
                    errors.append(f"{label} {v.get('version')}: {key} がありません")
    return errors


def cmd_validate(_args):
    errors = validate(load_source())
    for e in errors:
        print(f"error: {e}")
    if errors:
        sys.exit(1)
    print("source.json OK")


# ---------------------------------------------------------------- GitHub Releases

def gh(*args):
    return subprocess.run(["gh", *args], check=True, capture_output=True, text=True).stdout


def upload_release(tag, title, notes, files):
    exists = subprocess.run(["gh", "release", "view", tag, "--repo", HOST_REPO],
                            capture_output=True).returncode == 0
    paths = [str(f) for f in files]
    if exists:
        gh("release", "upload", tag, *paths, "--repo", HOST_REPO, "--clobber")
    else:
        gh("release", "create", tag, *paths, "--repo", HOST_REPO,
           "--title", title, "--notes", notes or title, "--latest=false")


def push_source():
    errors = validate(load_source())
    if errors:
        sys.exit("source.json を直してください:\n" + "\n".join(errors))
    with tempfile.TemporaryDirectory() as tmp:
        icon = Path(tmp) / "icon.png"
        icon.write_bytes(ICON.read_bytes())
        upload_release(SOURCE_TAG, "AltStore PAL source", "AltStore PAL の source.json", [SOURCE, icon])
    print(f"公開しました: {SOURCE_URL}")
    print(f"追加用リンク: altstore-pal://source?url={SOURCE_URL}")


def cmd_push_source(_args):
    push_source()



# ---------------------------------------------------------------- ADP

def fetch_adp(adp_id, workdir, timeout):
    """AltStore に ADP の処理を頼み、終わるのを待ってダウンロードする"""
    status, resp = api("POST", "/adps", {"adpID": adp_id})
    print(f"処理を依頼: HTTP {status} {resp}")
    start = time.monotonic()
    while True:
        status, resp = api("GET", f"/adps/{adp_id}")
        if url := resp.get("downloadURL"):
            break
        if time.monotonic() - start > timeout:
            sys.exit(f"{timeout} 秒待っても ADP の準備ができません: HTTP {status} {resp}")
        print(f"待機中: HTTP {status} {resp.get('status')}")
        time.sleep(30)
    dest = workdir / "adp.zip"
    print("ADP をダウンロード")
    with urllib.request.urlopen(url, timeout=600) as resp, open(dest, "wb") as out:
        while chunk := resp.read(1 << 20):
            out.write(chunk)
    return dest


def cmd_publish(args):
    src = load_source()
    with tempfile.TemporaryDirectory() as tmp:
        workdir = Path(tmp)
        archive = Path(args.adp_zip) if args.adp_zip else fetch_adp(args.adp_id, workdir, args.timeout)
        with zipfile.ZipFile(archive) as z:
            z.extractall(workdir / "adp")
        manifests = [p for p in (workdir / "adp").rglob("manifest.json") if "__MACOSX" not in p.parts]
        if len(manifests) != 1:
            sys.exit(f"ADP の中に manifest.json が {len(manifests)} 個あります")
        adp = manifests[0].parent
        # ADP の IPA は暗号化されているので、読めるのは manifest.json だけ
        manifest = json.loads((adp / "manifest.json").read_text(encoding="utf-8"))
        bundle_id = manifest["bundleId"]
        version, build = manifest["shortVersionString"], manifest["bundleVersion"]
        size = max((adp / v["assetPath"]).stat().st_size for v in manifest["variants"])
        print(f"ADP: {bundle_id} {version} ({build})、{len(manifest['variants'])} 種類")

        # Releases はフォルダを持てないので平らに置き、assetURLs でファイル名と URL を対応させる
        files = [p for p in sorted(adp.rglob("*")) if p.is_file() and p.name != ".DS_Store"]
        if len({p.name for p in files}) != len(files):
            sys.exit("ADP に同じ名前のファイルがあり、平らに置けません")
        app = find_source_app(src, bundle_id)
        tag = f"{bundle_id}-{version}-{build}"
        if args.dry_run:
            print(f"[dry-run] {len(files)} 個のファイルを {tag} に上げるところ")
        else:
            upload_release(tag, f"{app['name']} {version} ({build})", args.notes, files)

    entry = {
        "version": version,
        "buildVersion": build,
        "date": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "localizedDescription": args.notes or None,
        "downloadURL": release_url(tag, "manifest.json"),
        "size": size,
        "minOSVersion": manifest.get("minimumSystemVersions", {}).get("ios"),
        "assetURLs": {("manifest" if p.name == "manifest.json" else p.stem): release_url(tag, p.name)
                      for p in files},
    }
    app["versions"] = [{k: v for k, v in entry.items() if v is not None},
                       *(v for v in app["versions"] if (v["version"], v["buildVersion"]) != (version, build))]
    save_source(src)
    print(f"source.json に {version} ({build}) を足しました")
    if not args.dry_run:
        push_source()


# ---------------------------------------------------------------- CLI

def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)

    p = sub.add_parser("register", help="Developer ID を登録してトークンをもらう")
    p.add_argument("--developer-id", required=True,
                   help="App Store Connect → 右上の名前 → プロフィールを編集 の Developer ID（Team ID ではない）")
    p.add_argument("--email", required=True)
    p.set_defaults(func=cmd_register)

    p = sub.add_parser("permissions", help="entitlements と UsageDescription を source.json に書き出す")
    p.add_argument("--archive", dest="path", required=True, help=".app / .xcarchive / .ipa")
    p.set_defaults(func=cmd_permissions)

    p = sub.add_parser("validate", help="source.json を調べる")
    p.set_defaults(func=cmd_validate)

    p = sub.add_parser("push-source", help="source.json とアイコンを公開する")
    p.set_defaults(func=cmd_push_source)

    p = sub.add_parser("publish", help="公証済みの ADP を公開する")
    adp = p.add_mutually_exclusive_group(required=True)
    adp.add_argument("--adp-id", help="App Store Connect → アプリ → 配信 → 履歴 の ADP ID")
    adp.add_argument("--adp-zip", help="ダウンロード済みの ADP の zip")
    p.add_argument("--notes", default="", help="AltStore に出す更新内容")
    p.add_argument("--timeout", type=int, default=1800, help="ADP の処理を待つ秒数")
    p.add_argument("--dry-run", action="store_true", help="GitHub に上げない")
    p.set_defaults(func=cmd_publish)

    p = sub.add_parser("federate", help="explore.alt.store に載せる")
    p.set_defaults(func=cmd_federate)

    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
