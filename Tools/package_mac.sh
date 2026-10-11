#!/bin/zsh
# 友達の Mac に渡す zip を作る（Apple Developer Program なしで配る用）
# 正式な署名ができないのでアドホック署名にする。そのため次の機能は外す
#   - Share Extension（App Group が使えず、受け取ったファイルを本体に渡せない）
#   - キーチェーン（API キーはサンドボックス内のファイルに置く。KeychainStore 参照）
# 使い方: Tools/package_mac.sh  →  dist/文字起こし.zip
set -euo pipefail

SCHEME="VoiceNote"
APP_NAME="文字起こし"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED_DATA="$ROOT/DerivedData"
DIST="$ROOT/dist"

cd "$ROOT"

echo "==> xcodegen generate"
xcodegen generate --quiet

echo "==> ビルド（Intel と Apple シリコンの両方）"
xcodebuild -project VoiceNote.xcodeproj -scheme "$SCHEME" \
  -configuration Release \
  -destination 'generic/platform=macOS,variant=Mac Catalyst' \
  -derivedDataPath "$DERIVED_DATA" \
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=NO \
  -quiet build

echo "==> 署名"
rm -rf "$DIST"
mkdir -p "$DIST"
APP="$DIST/$APP_NAME.app"
cp -R "$DERIVED_DATA/Build/Products/Release-maccatalyst/$SCHEME.app" "$APP"
rm -rf "$APP/Contents/PlugIns"
ENTITLEMENTS="$(mktemp)"
cat > "$ENTITLEMENTS" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.security.app-sandbox</key>
	<true/>
	<key>com.apple.security.network.client</key>
	<true/>
	<key>com.apple.security.files.user-selected.read-only</key>
	<true/>
</dict>
</plist>
PLIST
codesign --force --deep --sign - --entitlements "$ENTITLEMENTS" "$APP"
rm "$ENTITLEMENTS"
codesign --verify --deep --strict "$APP"

echo "==> zip"
ditto -c -k --keepParent "$APP" "$DIST/$APP_NAME.zip"
echo "$DIST/$APP_NAME.zip"
