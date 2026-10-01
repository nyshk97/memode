#!/bin/bash
# Release ビルドを配布できる形に仕上げて dist/Memode-<version>.zip を作る（notarize の手前まで）
#
# 本体は Release 構成で Developer ID + --timestamp + Hardened Runtime + get-task-allow なしで署名される
# （project.yml）。例外が Sparkle.framework: xcodebuild は埋め込んだ framework の外側しか署名し直さず、
# 中の XPC サービス・Updater.app・Autoupdate が adhoc のまま残って notarize が Invalid になる。
# ここで内側から順に Developer ID + timestamp で署名し直し、最後に本体の封印も張り直す。
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/Build/Products/Release/Memode.app"
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
SPARKLE_B="$SPARKLE/Versions/B"
FEED_URL="${FEED_URL:-https://github.com/nyshk97/memode-releases/releases/latest/download/appcast.xml}"

# 署名 ID は scripts/gen-signing-xcconfig.sh が keychain から決めたもの（public リポジトリなので Team ID を書かない）
bash scripts/gen-signing-xcconfig.sh >/dev/null
IDENTITY=$(sed -n 's/^CODE_SIGN_IDENTITY = //p' signing-release.local.xcconfig)
if [ -z "$IDENTITY" ]; then
  echo "NG: Developer ID Application を決められない（signing-release.local.xcconfig を見る）" >&2
  exit 1
fi

# 前のビルドの残りを配らない
/bin/rm -rf build/Build/Products/Release dist 2>/dev/null || true
mkdir -p dist
(cd web && npm ci --no-audit --no-fund --silent && npm run build --silent >/dev/null)
xcodegen generate --quiet
xcodebuild -project memode.xcodeproj -scheme memode -configuration Release -derivedDataPath build build > build/xcodebuild-release.log 2>&1 \
  || { grep -E 'error:|\*\* BUILD' build/xcodebuild-release.log; exit 1; }

SPARKLE_NESTED=(
  "$SPARKLE_B/XPCServices/Downloader.xpc"
  "$SPARKLE_B/XPCServices/Installer.xpc"
  "$SPARKLE_B/Updater.app"
  "$SPARKLE_B/Autoupdate"
  "$SPARKLE"
)
for nested in "${SPARKLE_NESTED[@]}"; do
  [ -e "$nested" ] || { echo "NG: Sparkle の構成物が見つからない: $nested"; exit 1; }
  codesign --force --options runtime --timestamp --preserve-metadata=entitlements --sign "$IDENTITY" "$nested"
done
# 本体。--entitlements は渡さない（CODE_SIGN_INJECT_BASE_ENTITLEMENTS = NO なので get-task-allow は無い）
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"

fail=0
for target in "${SPARKLE_NESTED[@]}" "$APP"; do
  info=$(codesign -dvv "$target" 2>&1)
  case "$info" in *"Signature=adhoc"*) echo "NG: adhoc 署名が残っている: $target"; fail=1 ;; esac
  case "$info" in *"Authority=Developer ID Application:"*) ;; *) echo "NG: Developer ID の署名でない: $target"; fail=1 ;; esac
  case "$info" in *"Timestamp="*) ;; *) echo "NG: secure timestamp が無い: $target"; fail=1 ;; esac
  case "$info" in *"(runtime)"*) ;; *) echo "NG: Hardened Runtime が無効: $target"; fail=1 ;; esac
done
ent=$(codesign -d --entitlements - "$APP" 2>&1)
case "$ent" in *get-task-allow*) echo "NG: get-task-allow が残っている（配布では禁止）"; fail=1 ;; esac
codesign --verify --deep --strict "$APP" || fail=1

# 配信先は project.yml（アプリが見に行く先）と release.sh（appcast を置く先）の 2 箇所にあるので突き合わせる
PLIST="$APP/Contents/Info.plist"
built_feed=$(/usr/libexec/PlistBuddy -c "Print :SUFeedURL" "$PLIST" 2>/dev/null || true)
[ "$built_feed" = "$FEED_URL" ] || { echo "NG: SUFeedURL が配信先と違う: '${built_feed}'（期待: ${FEED_URL}）"; fail=1; }
built_key=$(/usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" "$PLIST" 2>/dev/null || true)
case "$built_key" in ""|*PLACEHOLDER*) echo "NG: SUPublicEDKey が未設定"; fail=1 ;; esac
[ -f "$APP/Contents/Resources/editor/index.html" ] || { echo "NG: エディタ部分（Resources/editor）が入っていない"; fail=1; }
[ -x "$APP/Contents/Resources/memode" ] || { echo "NG: memode コマンドが入っていない"; fail=1; }
[ "$fail" -eq 0 ] || exit 1

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PLIST")
ZIP="dist/Memode-$VERSION.zip"
# zip -r は symlink を実体に潰して署名を壊すので ditto を使う
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
echo "OK: $ZIP"
