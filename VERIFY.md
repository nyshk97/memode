# 動作確認

## dev 版の自走の検証（`--selftest`）

キーは dev 版のアプリの中で `NSEvent` を作って `NSApp.sendEvent` に流す（アクセシビリティの許可は要らず、メニューへの経路も本物と同じ）。
結果は `selftest.<名前> OK|NG <詳細>` の行でログに出る。**ポップアップが 10 秒ほど画面に出てキー入力を取る**ので、ユーザーが入力中でないときに回す。
クリップボードは途中で使うが、最後に元へ戻す（中身はログに出さない）。

**`--data-dir` と `--index-home` に使い捨てのディレクトリが必須**（付けないと `selftest.refused` で終わる）。タブを作ったり閉じたり
保存したりするので、手元の dev 版のメモ（`~/Memode-dev`）では回さない。Cmd+P の一覧も本物のホームを走査しない（時間がかかり、許可のダイアログも出る）。

```sh
mise run build
D=$(mktemp -d); mkdir -p "$D/home"; L=~/Library/Logs/memode-dev/memode.log; : > "$L"; mise run stop
open -g build/Build/Products/Debug/Memode-dev.app --args --selftest --selftest-quit --data-dir "$D" --index-home "$D/home"
for i in $(seq 1 160); do grep -q 'app.terminate' "$L" && break; sleep 0.5; done
grep -E 'NG|selftest.done|app.terminate|flush_timeout|js\.' "$L"
```

- `selftest.done ... ng=0` と `app.terminate flushed`（終了時に最後のセッションを書き終えてから終わった）が出れば通っている

- 確かめている項目: シンタックスハイライト・worker が動く・Cmd+Opt+↓ でカーソルが増える・Esc で戻る・Opt+↓ で行が動く・
  Cmd+N/P/S/Shift+S/W/1・Ctrl+Tab・Cmd+\ がメニューに届く・Cmd+A/C/X/V・Cmd+O のファイル選択画面がポップアップより前に出る・
  閉じた後にポップアップがキーを取り戻す・隠して出し直したときにフォーカスとカーソル位置が戻る
  タブと分割（1 行目の見出し・Cmd+N・Cmd+1・Ctrl+Tab・分割で同じ文書が開く・分割を戻してもタブが残る・言語の選択・全部閉じると空のメモが 1 枚）・
  左 Shift のダブルタップ（出す・隠す・他のキーで取り消し・遅すぎ・右 Shift）。ダブルタップは、監視から届いたイベントと同じ入口（`ShiftTapMonitor.feed`）に流す
  保存（メモを Cmd+S・上書き・CRLF を保つ）・外での書き換え（変更が無ければ読み直す・あれば聞く・同じ書き換えは 2 度聞かない）・
  未保存の変更があるファイルの Cmd+W（キャンセル・保存しない）・セッションの書き出し。保存ダイアログだけは飛ばす（`savePathOverride`）
  ファイルを開く（Cmd+O・Cmd+P のあいまい検索・memode:// で記号入りのパス・無いパス・ディレクトリの登録・相対パスは無視）。ファイル選択だけは飛ばす（`openPathOverride`）。
  Cmd+P の一覧は偽のホームに「入るもの（Dropbox・深い隠しディレクトリ・git の未コミット）」と「入らないもの（OrbStack・Library・
  ホーム直下の隠しディレクトリ・node_modules・.gitignore・.ssh）」を作って確かめる
- 日本語入力（IME）・全画面アプリの上に出るか・実際のキーボードからのダブルタップ・外のクリックで隠れるかは、自走では確かめられない。人が試す

## 再起動後の復元（`--selftest-restore`）

上の `--selftest` の直後に、同じ `$D` で続ける。`--selftest` の終わりに、メモ・CRLF のファイル・未保存の変更があるファイルの 3 枚が残っている。

```sh
# crlf.txt に BOM を付けておく（未保存の変更が無いファイルはディスクから読み直すので、BOM の扱いまで確かめられる）
python3 -c "p='$D/files/crlf.txt'; b=open(p,'rb').read(); open(p,'wb').write(b'\xef\xbb\xbf'+b)"
: > "$L"; open -g build/Build/Products/Debug/Memode-dev.app --args --selftest-restore --data-dir "$D" --index-home "$D/home"
for i in $(seq 1 60); do grep -q 'selftest.done' "$L" && break; sleep 0.5; done
grep -E 'selftest\.|session\.|js\.' "$L"
# 落ちたとき: 書き換えから 1 秒後に kill -9 しても session.json に残っている
pkill -9 -x Memode-dev; grep -c 'kill-9 の前に書いた' "$D/session.json"
```

- 確かめていること: 3 枚のタブが戻る・未保存の変更があるファイルは変更つきで戻る・最後に見ていたタブ・CRLF のファイルはディスクから読み直す・
  保存しても BOM と CRLF がバイト単位で保たれる（`efbbbf63310d0a...`）
- 壊れた session.json: `printf '{"docs": [ broken' > "$D2/session.json"` を置いて `--data-dir "$D2"` で起動すると、
  `session.broken moved to .../session.broken-<日時>.json` が出て、空の状態で起動する

## 本物のホームの一覧（件数と時間）

手元の dev 版を起動すると、起動時に一覧を作って件数・時間・場所ごとの内訳をログに出す。

```sh
grep -E 'folder\.indexed' ~/Library/Logs/memode-dev/memode.log
# folder.indexed /Users/d0ne1s files=8391 ms=478
# folder.indexed_by_dir Downloads=2273 ... Library/CloudStorage/Dropbox=492 ...
```

`ms` が何十秒にもなっていたら、許可のダイアログ（`~/Documents`・Dropbox 等）が返事待ちで止まっていないかを見る（2026-10-01 に 133 秒になった）。

## memode コマンド

dev 版を使い捨てのデータの置き場所で起動しておき、`--dev` で流す（付けないと常用版が起動する）。

```sh
D=$(mktemp -d); mkdir -p "$D/work"; printf 'x\n' > "$D/work/日本語 #メモ & q?.txt"
open -g build/Build/Products/Debug/Memode-dev.app --args --data-dir "$D"; sleep 2.5
(cd "$D/work" && ~/memode/scripts/memode --dev "日本語 #メモ & q?.txt" "まだ無い.md")
grep -E 'url.open|file\.(opened|open_new|open_failed)' ~/Library/Logs/memode-dev/memode.log
```

`file.opened ...日本語 #メモ & q?.txt` と `file.open_new ...まだ無い.md` が出れば通っている。

## ユニットテスト

```sh
mise run test   # ダブルタップの判定・隠す決まり・ファイルの読み書き（BOM・CRLF・UTF-8 以外・バイナリ・外での書き換え）・フォルダの一覧（git / 走査）
```

アプリを起動しないので、dev 版が動いていても回せる。

## 見た目の確認（スクリーンショット）

`--demo` を付けると、タブを 3 枚開いて左右に分割した状態で出る（`--show` なら空のメモ 1 枚）。

```sh
open -g build/Build/Products/Debug/Memode-dev.app --args --demo; sleep 3
WID=$(osascript -l JavaScript -e 'ObjC.import("CoreGraphics"); const l=ObjC.deepUnwrap(ObjC.castRefToObject($.CGWindowListCopyWindowInfo(1,0))); const w=l.filter(x=>x.kCGWindowOwnerName==="Memode-dev" && x.kCGWindowLayer>0 && x.kCGWindowBounds.Height>200)[0]; w? String(w.kCGWindowNumber):""')
screencapture -x -o -l "$WID" /tmp/memode-panel.png; mise run stop
```

## ビルド成果物の確認

- 署名: `codesign -dvv build/Build/Products/Debug/Memode-dev.app 2>&1 | grep Authority` が `Apple Development` であること（ad-hoc だとアクセシビリティの許可がリビルドのたびに外れる）
- Info.plist: `PlistBuddy -c 'Print :CFBundleURLTypes:0:CFBundleURLSchemes:0'` が dev 版では `memode-dev`
- Web のビルドが入っているか: `ls build/Build/Products/Debug/Memode-dev.app/Contents/Resources/editor`
