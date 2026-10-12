#!/bin/zsh
# 友達の Mac に渡す zip を作る（Developer ID で署名して Apple の公証を通す）
# 公証済みなので、受け取った側はダウンロードしてそのまま開ける
# 事前に必要なこと
#   - Xcode に Apple Developer Program のアカウント（Admin 以上）でログインしておく
#     Developer ID の証明書とプロファイルは初回に自動で作られる
# 使い方: Tools/package_mac.sh  →  dist/文字起こし.zip
set -euo pipefail

SCHEME="VoiceNote"
APP_NAME="文字起こし"
TEAM_ID="R5PQN893BB"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED_DATA="$ROOT/DerivedData"
DIST="$ROOT/dist"
OUT="$DIST/mac"
ARCHIVE="$OUT/$SCHEME.xcarchive"

cd "$ROOT"

echo "==> xcodegen generate"
xcodegen generate --quiet

echo "==> アーカイブ（Intel と Apple シリコンの両方）"
rm -rf "$OUT" "$DIST/$APP_NAME.app" "$DIST/$APP_NAME.zip"
mkdir -p "$OUT"
xcodebuild -project VoiceNote.xcodeproj -scheme "$SCHEME" \
  -configuration Release \
  -destination 'generic/platform=macOS,variant=Mac Catalyst' \
  -derivedDataPath "$DERIVED_DATA" \
  -archivePath "$ARCHIVE" \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
  -quiet archive

echo "==> Developer ID で署名して公証に出す"
OPTIONS="$OUT/ExportOptions.plist"
cat > "$OPTIONS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>developer-id</string>
	<key>destination</key>
	<string>upload</string>
	<key>teamID</key>
	<string>$TEAM_ID</string>
	<key>signingStyle</key>
	<string>automatic</string>
</dict>
</plist>
PLIST
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportOptionsPlist "$OPTIONS" \
  -exportPath "$OUT/upload" \
  -allowProvisioningUpdates

# 公証が終わるまでは書き出しが失敗するので、通るまで繰り返す
echo "==> 公証を待つ"
for attempt in {1..60}; do
  if xcodebuild -exportNotarizedApp -archivePath "$ARCHIVE" -exportPath "$OUT/notarized" > "$OUT/notarize.log" 2>&1; then
    break
  fi
  if ! grep -q "not ready for distribution" "$OUT/notarize.log"; then
    cat "$OUT/notarize.log"
    exit 1
  fi
  (( attempt == 60 )) && { echo "公証が30分で終わりませんでした"; exit 1; }
  sleep 30
done

echo "==> 確認"
APP="$DIST/$APP_NAME.app"
ditto "$OUT/notarized/$SCHEME.app" "$APP"
codesign --verify --deep --strict "$APP"
xcrun stapler validate "$APP"
spctl --assess --type exec "$APP"

echo "==> zip"
ditto -c -k --keepParent "$APP" "$DIST/$APP_NAME.zip"
echo "$DIST/$APP_NAME.zip"
