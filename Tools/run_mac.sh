#!/bin/zsh
# Mac（Mac Catalyst）向けにビルドして起動する
# 初回は Xcode に Apple ID でログインしておく必要がある（この Mac の登録とプロファイル作成を自動で行う）
# 使い方: Tools/run_mac.sh
set -euo pipefail

SCHEME="VoiceNote"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED_DATA="$ROOT/DerivedData"

cd "$ROOT"

echo "==> xcodegen generate"
xcodegen generate --quiet

echo "==> ビルド"
xcodebuild -project VoiceNote.xcodeproj -scheme "$SCHEME" \
  -configuration Debug \
  -destination 'platform=macOS,variant=Mac Catalyst' \
  -derivedDataPath "$DERIVED_DATA" \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
  -quiet build

echo "==> 起動"
osascript -e 'quit app id "jp.haru.VoiceNote"' 2>/dev/null || true
open "$DERIVED_DATA/Build/Products/Debug-maccatalyst/$SCHEME.app"
