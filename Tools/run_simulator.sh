#!/bin/zsh
# シミュレーターにビルド・インストールして起動する
# 使い方: Tools/run_simulator.sh ["iPhone 17"]
set -euo pipefail

DEVICE_NAME="${1:-iPhone 17}"
SCHEME="NanpaVoice"
BUNDLE_ID="jp.haru.NanpaVoice"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED_DATA="$ROOT/DerivedData"

cd "$ROOT"

echo "==> xcodegen generate"
xcodegen generate --quiet

# 同名の端末が複数 OS にある場合は最新の OS を選ぶ
UDID="$(xcrun simctl list devices available -j | python3 -c '
import json, sys
name = sys.argv[1]
devices = json.load(sys.stdin)["devices"]
for runtime in sorted(devices, reverse=True):
    for d in devices[runtime]:
        if d["name"] == name:
            print(d["udid"])
            sys.exit(0)
sys.exit(1)
' "$DEVICE_NAME")" || {
  echo "シミュレーター \"$DEVICE_NAME\" が見つかりません" >&2
  exit 1
}

echo "==> $DEVICE_NAME ($UDID) を起動"
xcrun simctl bootstatus "$UDID" -b >/dev/null
open -a Simulator

echo "==> ビルド"
xcodebuild -project NanpaVoice.xcodeproj -scheme "$SCHEME" \
  -configuration Debug \
  -destination "id=$UDID" \
  -derivedDataPath "$DERIVED_DATA" \
  -quiet build

echo "==> インストール"
xcrun simctl install "$UDID" "$DERIVED_DATA/Build/Products/Debug-iphonesimulator/$SCHEME.app"

echo "==> 起動"
xcrun simctl terminate "$UDID" "$BUNDLE_ID" 2>/dev/null || true
xcrun simctl launch "$UDID" "$BUNDLE_ID"
