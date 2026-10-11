#!/bin/zsh
# iPhone 実機向けに署名してビルドし、インストールして起動する
# 事前に必要なこと
#   - Xcode に Apple ID でログインしておく（端末の登録とプロファイル作成はビルド時に自動で行う）
#   - iPhone を USB か同じ Wi-Fi でつなぎ、デベロッパモードをオンにしておく
# 使い方: Tools/run_iphone.sh ["iPhone の名前"]
set -euo pipefail

DEVICE_NAME="${1:-}"
SCHEME="NanpaVoice"
BUNDLE_ID="jp.haru.NanpaVoice"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED_DATA="$ROOT/DerivedData"

cd "$ROOT"

echo "==> xcodegen generate"
xcodegen generate --quiet

# 接続中の iPhone を探す。devicectl の識別子とビルド先に渡す UDID は別物なので両方取る
DEVICES_JSON="$(mktemp)"
trap 'rm -f "$DEVICES_JSON"' EXIT
xcrun devicectl list devices -j "$DEVICES_JSON" -q
DEVICE="$(python3 -c '
import json, sys
name = sys.argv[2]
for d in json.load(open(sys.argv[1]))["result"]["devices"]:
    if d["hardwareProperties"].get("platform") != "iOS":
        continue
    if d["connectionProperties"].get("tunnelState") == "unavailable":
        continue
    if name and d["deviceProperties"]["name"] != name:
        continue
    print(d["identifier"], d["hardwareProperties"]["udid"])
    sys.exit(0)
sys.exit(1)
' "$DEVICES_JSON" "$DEVICE_NAME")" || {
  echo "接続中の iPhone が見つかりません。USB でつなぐか、同じ Wi-Fi で iPhone のロックを解除してください" >&2
  exit 1
}
read -r DEVICE_ID DEVICE_UDID <<<"$DEVICE"

echo "==> ビルド（$DEVICE_UDID）"
xcodebuild -project NanpaVoice.xcodeproj -scheme "$SCHEME" \
  -configuration Release \
  -destination "id=$DEVICE_UDID" \
  -derivedDataPath "$DERIVED_DATA" \
  -allowProvisioningUpdates \
  -allowProvisioningDeviceRegistration \
  -quiet build

echo "==> インストール"
xcrun devicectl device install app --device "$DEVICE_ID" \
  "$DERIVED_DATA/Build/Products/Release-iphoneos/$SCHEME.app"

echo "==> 起動"
xcrun devicectl device process launch --device "$DEVICE_ID" --terminate-existing "$BUNDLE_ID"
