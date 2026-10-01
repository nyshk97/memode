#!/bin/bash
# dist/Memode-<version>.zip を notarize して、staple 済みの zip に差し替える。
# 資格情報は keychain プロファイル（既定 nyshk97-notary。App Store Connect の API キー）
set -euo pipefail
cd "$(dirname "$0")/.."

PROFILE="${NOTARY_PROFILE:-nyshk97-notary}"
APP="build/Build/Products/Release/Memode.app"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
ZIP="dist/Memode-$VERSION.zip"
[ -f "$ZIP" ] || { echo "NG: $ZIP が無い（先に scripts/make-release-zip.sh）"; exit 1; }

xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait

# staple は .app に貼る。展開して貼り、貼ったものを zip し直す
STAPLE_DIR=$(mktemp -d)
trap '/bin/rm -rf "$STAPLE_DIR" 2>/dev/null || true' EXIT
ditto -x -k "$ZIP" "$STAPLE_DIR"
xcrun stapler staple "$STAPLE_DIR/Memode.app"
assess=$(spctl --assess --type execute -vv "$STAPLE_DIR/Memode.app" 2>&1)
case "$assess" in
  *"Notarized Developer ID"*) ;;
  *) echo "NG: Gatekeeper の評価が通らない: $assess"; exit 1 ;;
esac
# 検証を通ったものだけを zip の名前に置く
ditto -c -k --sequesterRsrc --keepParent "$STAPLE_DIR/Memode.app" "$ZIP.tmp"
mv "$ZIP.tmp" "$ZIP"
echo "OK: staple 済み $ZIP"
