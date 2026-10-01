#!/bin/bash
# Memode のリリース（MenuBar Tidy の scripts/release.sh が原本）
# 使い方: scripts/release.sh [patch|minor|major|<x.y.z>]   （省略時は patch）
#
# 0. 事前チェック（clean な作業ツリー・HEAD == origin/main・Release が未作成・[Unreleased] が空でない・
#    画面がロックされていない・署名の証明書・notarize の資格情報・Sparkle の鍵）
# 1. project.yml の MARKETING_VERSION を上げ、CHANGELOG の [Unreleased] を [<version>] に切り出して commit（push はまだ）
# 2. make-release-zip.sh（Release ビルド・署名・検証・zip）→ notarize.sh（notarize・staple）
# 3. zip に Sparkle の EdDSA 署名を付けて dist/appcast.xml を作る
# 4. main を push → 配信用のリポジトリ（nyshk97/memode-releases）に GitHub Release を作る
# 5. nyshk97/homebrew-tap の Casks/memode.rb を作成・更新し、ローカルの tap を同期する
#
# push より前に失敗したら、trap が bump の commit を巻き戻す（remote には何も出ない）。
# Claude Code のセッションから叩いてよい（submit の数分間に画面がロックされないことだけが条件）
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

APP_NAME="Memode"
BUNDLE_ID="local.nyshk97.memode"
NOTARY_PROFILE="${NOTARY_PROFILE:-nyshk97-notary}"
SOURCE_REPO="nyshk97/memode"
RELEASES_REPO="nyshk97/memode-releases"
export FEED_URL="https://github.com/$RELEASES_REPO/releases/latest/download/appcast.xml"
TAP_REPO="nyshk97/homebrew-tap"
CASK_TOKEN="memode"
CASK_PATH="Casks/${CASK_TOKEN}.rb"
SPARKLE_ACCOUNT="memode"
SIGN_UPDATE="$REPO_ROOT/build/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update"
APPCAST="$REPO_ROOT/dist/appcast.xml"
CHANGELOG_PY="$REPO_ROOT/scripts/changelog.py"

# ===== バージョン計算 =====
CURRENT_VERSION="$(sed -n 's/^ *MARKETING_VERSION: *//p' project.yml | head -1)"
echo "現在のバージョン: ${CURRENT_VERSION}"
BUMP="${1:-patch}"
IFS='.' read -r MAJOR MINOR PATCH <<< "$CURRENT_VERSION"
case "$BUMP" in
  major) MAJOR=$((MAJOR + 1)); MINOR=0; PATCH=0 ;;
  minor) MINOR=$((MINOR + 1)); PATCH=0 ;;
  patch) PATCH=$((PATCH + 1)) ;;
  [0-9]*.[0-9]*.[0-9]*) IFS='.' read -r MAJOR MINOR PATCH <<< "$BUMP" ;;
  *) echo "不正なバージョン指定: ${BUMP}（patch|minor|major|x.y.z）"; exit 1 ;;
esac
NEW_VERSION="$MAJOR.$MINOR.$PATCH"
TAG="v$NEW_VERSION"
DIST_ZIP="$REPO_ROOT/dist/Memode-$NEW_VERSION.zip"
echo "新しいバージョン: ${NEW_VERSION}"

# ===== 事前チェック（壊す前に全部見る）=====
if [ -n "$(git status --porcelain)" ]; then
  echo "❌ 作業ツリーに未コミットの変更（未追跡のファイルを含む）がある。コミットしてから実行する"
  git status --short
  exit 1
fi
git fetch -q origin
if [ "$(git rev-parse HEAD)" != "$(git rev-parse origin/main)" ]; then
  echo "❌ HEAD が origin/main と一致しない（pull 忘れ / push 忘れ）"
  echo "   local : $(git rev-parse --short HEAD)"
  echo "   origin: $(git rev-parse --short origin/main)"
  exit 1
fi
if ! gh auth status >/dev/null 2>&1; then
  echo "❌ gh が未認証。gh auth login を先に済ませる"
  exit 1
fi
if ! gh repo view "$RELEASES_REPO" >/dev/null 2>&1; then
  echo "❌ 配信用のリポジトリ $RELEASES_REPO が見つからない（gh の失敗と区別するため、先に gh repo view で確かめる）"
  exit 1
fi
if gh release view "$TAG" --repo "$RELEASES_REPO" >/dev/null 2>&1; then
  echo "❌ リリース $TAG は既にある"
  exit 1
fi
python3 "$CHANGELOG_PY" check
CONSOLE_LOCKED="$(ioreg -n Root -d1 -a 2>/dev/null | plutil -extract IOConsoleLocked raw -o - - 2>/dev/null || true)"
if [ "$CONSOLE_LOCKED" = "true" ]; then
  echo "❌ 画面がロックされている。notarize の資格情報が読めないので、解除してから実行する"
  exit 1
fi
bash scripts/gen-signing-xcconfig.sh >/dev/null
if [ -z "$(sed -n 's/^CODE_SIGN_IDENTITY = //p' signing-release.local.xcconfig)" ]; then
  echo "❌ Developer ID Application の証明書を決められない（scripts/gen-signing-xcconfig.sh の警告を見る）"
  exit 1
fi
if ! NOTARY_CHECK="$(xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" 2>&1)"; then
  echo "❌ notarize の keychain プロファイル '${NOTARY_PROFILE}' が使えない:"
  echo "$NOTARY_CHECK" | head -3
  echo "   作り方は ~/Library/CloudStorage/Dropbox/dotfiles/.claude/references/personal-mac-apps.md の「notarize の資格情報」"
  exit 1
fi
if ! security find-generic-password -s "https://sparkle-project.org" -a "$SPARKLE_ACCOUNT" >/dev/null 2>&1; then
  echo "❌ Sparkle の EdDSA 秘密鍵（keychain account '${SPARKLE_ACCOUNT}'）が無い"
  echo "   復元: build/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys --account $SPARKLE_ACCOUNT -f ~/Library/CloudStorage/Dropbox/secrets/sparkle-ed25519-memode-private.key"
  exit 1
fi

# ===== バージョンを上げて commit（push は notarize の後）=====
sed -i '' "s/^\( *MARKETING_VERSION: *\).*/\1$NEW_VERSION/" project.yml
python3 "$CHANGELOG_PY" release "$NEW_VERSION" "$(date +%Y-%m-%d)"
git add project.yml docs/CHANGELOG.md
git commit -q -m "chore: bump version to $TAG"
BUMP_PUSHED=0
# 事前チェックで作業ツリーが clean なことは確かめてあるので、--hard で戻して消えるのは今の bump だけ
rollback_bump() {
  if [ "$BUMP_PUSHED" -eq 0 ]; then
    echo "↩️  失敗したので bump の commit を巻き戻す（remote は変えていない）"
    git reset -q --hard HEAD~1
  fi
}
trap 'rollback_bump' ERR

# ===== ビルド・署名・検証・notarize =====
bash scripts/make-release-zip.sh
bash scripts/notarize.sh
[ -f "$DIST_ZIP" ] || { echo "❌ 配布する zip が無い: $DIST_ZIP"; exit 1; }
BUILT_VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" build/Build/Products/Release/Memode.app/Contents/Info.plist)"
[ "$BUILT_VERSION" = "$NEW_VERSION" ] || { echo "❌ ビルドの CFBundleVersion（${BUILT_VERSION}）が $NEW_VERSION と違う"; exit 1; }
SHA256="$(shasum -a 256 "$DIST_ZIP" | awk '{print $1}')"

# ===== Sparkle: EdDSA 署名 + appcast =====
[ -x "$SIGN_UPDATE" ] || { echo "❌ sign_update が無い: $SIGN_UPDATE"; exit 1; }
echo "🔏 Sparkle の EdDSA 署名を付けています..."
ED_ATTRS="$("$SIGN_UPDATE" --account "$SPARKLE_ACCOUNT" "$DIST_ZIP")"
case "$ED_ATTRS" in
  *sparkle:edSignature=*) ;;
  *) echo "❌ sign_update の出力が想定と違う: $ED_ATTRS"; exit 1 ;;
esac
RELEASE_NOTES_MD="$REPO_ROOT/dist/release-notes-$NEW_VERSION.md"
SPARKLE_DESC_HTML="$REPO_ROOT/dist/sparkle-description-$NEW_VERSION.html"
python3 "$CHANGELOG_PY" notes "$NEW_VERSION" "$RELEASE_NOTES_MD" "$SPARKLE_DESC_HTML"
PUBDATE="$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")"
DOWNLOAD_URL="https://github.com/$RELEASES_REPO/releases/download/$TAG/Memode-$NEW_VERSION.zip"
RELEASE_URL="https://github.com/$RELEASES_REPO/releases/tag/$TAG"
# feed は releases/latest/download/appcast.xml で常に最新の Release のものを指すので、item は 1 つでよい
cat > "$APPCAST" <<APPCAST_EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>$APP_NAME</title>
    <item>
      <title>$TAG</title>
      <pubDate>$PUBDATE</pubDate>
      <sparkle:version>$NEW_VERSION</sparkle:version>
      <sparkle:shortVersionString>$NEW_VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <sparkle:fullReleaseNotesLink>$RELEASE_URL</sparkle:fullReleaseNotesLink>
      <description><![CDATA[
$(cat "$SPARKLE_DESC_HTML")
]]></description>
      <enclosure url="$DOWNLOAD_URL" $ED_ATTRS type="application/octet-stream"/>
    </item>
  </channel>
</rss>
APPCAST_EOF
xmllint --noout "$APPCAST"

# ===== push → Release（順番はこの通り。先にタグを打つと、後で失敗したとき中身の無いタグが残る）=====
git push origin main
BUMP_PUSHED=1
trap - ERR
echo "🚀 GitHub Release を作成中..."
gh release create "$TAG" "$DIST_ZIP" "$APPCAST" \
  --repo "$RELEASES_REPO" \
  --title "Memode $TAG" \
  --notes-file "$RELEASE_NOTES_MD"

# ===== cask（nyshk97/homebrew-tap）=====
echo "🍺 cask $CASK_PATH を更新中..."
CASK_CONTENT="$(cat <<CASK
cask "$CASK_TOKEN" do
  version "$NEW_VERSION"
  sha256 "$SHA256"

  url "https://github.com/$RELEASES_REPO/releases/download/v#{version}/Memode-#{version}.zip"
  name "$APP_NAME"
  desc "左 Shift のダブルタップで出し入れするポップアップのメモ・エディタ"
  homepage "https://github.com/$SOURCE_REPO"

  depends_on macos: ">= :sonoma"

  app "$APP_NAME.app"
  binary "#{appdir}/$APP_NAME.app/Contents/Resources/memode"

  uninstall quit: "$BUNDLE_ID"

  # メモ（~/Library/Application Support/Memode）は消さない
  zap trash: [
    "~/Library/Logs/memode",
    "~/Library/Preferences/$BUNDLE_ID.plist",
  ]

  caveats <<~EOS
    左 Shift のダブルタップを使うには、アクセシビリティの許可が必要です
    （システム設定 → プライバシーとセキュリティ → アクセシビリティ）。
  EOS
end
CASK
)"
ENCODED="$(printf '%s' "$CASK_CONTENT" | base64)"
EXISTING_SHA="$(gh api "repos/$TAP_REPO/contents/$CASK_PATH" --jq '.sha' 2>/dev/null || true)"
if [ -n "$EXISTING_SHA" ]; then
  gh api "repos/$TAP_REPO/contents/$CASK_PATH" --method PUT \
    --field message="chore: $CASK_TOKEN $NEW_VERSION" --field content="$ENCODED" --field sha="$EXISTING_SHA" --silent
else
  gh api "repos/$TAP_REPO/contents/$CASK_PATH" --method PUT \
    --field message="feat: add $CASK_TOKEN $NEW_VERSION" --field content="$ENCODED" --silent
fi
# brew のローカルの tap は自動で更新されないので、ここで pull しておく（しないと brew bundle が「No available cask」）
TAP_DIR="$(brew --repository nyshk97/tap 2>/dev/null || true)"
if [ -n "$TAP_DIR" ] && [ -d "$TAP_DIR/.git" ]; then
  git -C "$TAP_DIR" pull --ff-only --quiet origin main || true
fi

echo ""
echo "✅ リリース完了: $TAG"
echo "   asset : $DOWNLOAD_URL"
echo "   sha256: $SHA256"
echo "   feed  : $FEED_URL"
echo "   cask  : $TAP_REPO $CASK_PATH"
