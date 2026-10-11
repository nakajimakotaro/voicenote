#!/bin/zsh
# iOS 版をアーカイブして App Store Connect にアップロードする（AltStore PAL 向けの公証に出す用）
# 事前に必要なこと
#   - Xcode に Apple Developer Program のアカウントでログインしておく
#   - チームに端末を1台以上登録しておく（アーカイブは開発用の署名で作るため。Tools/run_iphone.sh を一度動かせば登録される）
#   - App Store Connect に jp.haru.NanpaVoice のアプリを作っておく
# ビルド番号はアップロードごとに変える必要があるので、日時から作る
# 使い方: Tools/upload_appstore.sh [--no-upload]
#   --no-upload  アップロードせず、ipa と AltStore 用の権限の書き出しまで行う
set -euo pipefail

SCHEME="NanpaVoice"
TEAM_ID="R5PQN893BB"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED_DATA="$ROOT/DerivedData"
OUT="$ROOT/dist/appstore"
ARCHIVE="$OUT/$SCHEME.xcarchive"
BUILD_NUMBER="$(date +%Y%m%d%H%M)"

UPLOAD=1
[[ "${1:-}" == "--no-upload" ]] && UPLOAD=0

cd "$ROOT"

echo "==> xcodegen generate"
xcodegen generate --quiet

echo "==> アーカイブ（ビルド番号 $BUILD_NUMBER）"
rm -rf "$OUT"
mkdir -p "$OUT"
xcodebuild -project NanpaVoice.xcodeproj -scheme "$SCHEME" \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$DERIVED_DATA" \
  -archivePath "$ARCHIVE" \
  -allowProvisioningUpdates \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  -quiet archive

# App Store 用の署名で一度ローカルに書き出し、Apple に送るものと同じ entitlements を AltStore 用に読む
export_archive() {
  local destination="$1"
  local options="$OUT/ExportOptions-$destination.plist"
  cat > "$options" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>app-store-connect</string>
	<key>destination</key>
	<string>$destination</string>
	<key>teamID</key>
	<string>$TEAM_ID</string>
	<key>signingStyle</key>
	<string>automatic</string>
	<key>manageAppVersionAndBuildNumber</key>
	<false/>
</dict>
</plist>
PLIST
  xcodebuild -exportArchive \
    -archivePath "$ARCHIVE" \
    -exportOptionsPlist "$options" \
    -exportPath "$OUT/$destination" \
    -allowProvisioningUpdates
}

echo "==> 書き出し"
export_archive export

echo "==> AltStore の source.json に権限を書き出す"
python3 Tools/altstore.py permissions --archive "$OUT/export/$SCHEME.ipa"

if (( ! UPLOAD )); then
  echo "$OUT/export/$SCHEME.ipa"
  exit 0
fi

echo "==> アップロード"
export_archive upload

echo "アップロードしました（ビルド $BUILD_NUMBER）。App Store Connect で処理が終わったら公証に出してください"
