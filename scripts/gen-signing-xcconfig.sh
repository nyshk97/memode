#!/bin/bash
# 署名証明書のハッシュはマシンごとに違うので、project.yml に直書きせず keychain から引いて
# gitignore した *.local.xcconfig に書き出す。ハッシュで固定するのは、リビルドのたびに
# アクセシビリティの許可（TCC）が外れないようにするため。
# public リポジトリなので Team ID もリポジトリに書かない。配布用の Developer ID は
#   1. 環境変数 MEMODE_RELEASE_TEAM_ID
#   2. .release-team.local（gitignore。Team ID を 1 行）
#   3. keychain に Developer ID Application がちょうど 1 枚ならそれ
# の順で決める。0 枚・複数枚なのに絞れないときは Release 用を書かずに警告する。
set -euo pipefail
cd "$(dirname "$0")/.."

ids=$(security find-identity -v -p codesigning)
debug_hash=$(echo "$ids" | awk '/"Apple Development/ {print $2; exit}')

team="${MEMODE_RELEASE_TEAM_ID:-}"
if [ -z "$team" ] && [ -f .release-team.local ]; then
  team=$(tr -d '[:space:]' < .release-team.local)
fi
if [ -n "$team" ]; then
  release_hash=$(echo "$ids" | awk -v t="($team)\"" '/"Developer ID Application/ && index($0, t) {print $2; exit}')
else
  count=$(echo "$ids" | grep -c '"Developer ID Application' || true)
  if [ "$count" = "1" ]; then
    release_hash=$(echo "$ids" | awk '/"Developer ID Application/ {print $2; exit}')
  else
    release_hash=""
    echo "signing: 警告: Developer ID Application が ${count} 枚ある。MEMODE_RELEASE_TEAM_ID か .release-team.local で Team ID を指定する" >&2
  fi
fi

# 同じ内容なら書き換えない（mtime が動くと全リビルドが走る）
write_if_changed() {
  local path=$1 content=$2
  if [ ! -f "$path" ] || [ "$(cat "$path")" != "$content" ]; then
    printf '%s\n' "$content" > "$path"
    echo "signing: ${path} を更新した"
  fi
}

header="// scripts/gen-signing-xcconfig.sh が生成（マシン固有・コミットしない）"

if [ -n "$debug_hash" ]; then
  write_if_changed signing-debug.local.xcconfig "$header
CODE_SIGN_IDENTITY = $debug_hash"
else
  # ad-hoc でもビルドは通すが、リビルドのたびにアクセシビリティの許可が外れる
  write_if_changed signing-debug.local.xcconfig "$header
// Apple Development 証明書が無いので ad-hoc
CODE_SIGN_IDENTITY = -"
  echo "signing: 警告: Apple Development 証明書が無いので ad-hoc で署名する。この状態では左 Shift の検知（Phase 3 以降）の検証を進めない" >&2
fi

if [ -n "$release_hash" ]; then
  write_if_changed signing-release.local.xcconfig "$header
CODE_SIGN_IDENTITY = $release_hash"
else
  write_if_changed signing-release.local.xcconfig "$header
// Developer ID Application を決められなかった（Release ビルドは署名で失敗する）"
fi
