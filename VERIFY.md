# 動作確認

## dev 版の自走の検証（`--selftest`）

キーは dev 版のアプリの中で `NSEvent` を作って `NSApp.sendEvent` に流す（アクセシビリティの許可は要らず、メニューへの経路も本物と同じ）。
結果は `selftest.<名前> OK|NG <詳細>` の行でログに出る。**ポップアップが 10 秒ほど画面に出てキー入力を取る**ので、ユーザーが入力中でないときに回す。
クリップボードは途中で使うが、最後に元へ戻す（中身はログに出さない）。

**`--data-dir` と `--index-home` に使い捨てのディレクトリが必須**（付けないと `selftest.refused` で終わる）。タブを作ったり閉じたり
保存したりするので、手元の dev 版のメモ（`~/Library/Application Support/Memode-dev`）では回さない。Cmd+P の一覧も本物のホームを走査しない（時間がかかり、許可のダイアログも出る）。

```sh
mise run build
D=$(mktemp -d); mkdir -p "$D/home"; L=~/Library/Logs/memode-dev/memode.log; : > "$L"; mise run stop
open -g build/Build/Products/Debug/Memode-dev.app --args --selftest --selftest-quit --data-dir "$D" --index-home "$D/home"
for i in $(seq 1 160); do grep -q 'app.terminate' "$L" && break; sleep 0.5; done
grep -E 'NG|selftest.done|app.terminate|flush_timeout|js\.' "$L"
```

- `selftest.done ... ng=0` と `app.terminate flushed`（終了時に最後のセッションを書き終えてから終わった）が出れば通っている

- 確かめている項目: シンタックスハイライト・worker が動く・言語の判定（拡張子・ファイル名・shebang）と JSON・TOML（ini）・ignore・diff の色付け・Cmd+Opt+↓ でカーソルが増える・Esc で戻る・Opt+↓ で行が動く・
  Cmd+N/P/S/Shift+S/W/1・Ctrl+Tab・Cmd+Opt+←→・Cmd+\ がメニューに届く・Cmd+A/C/X/V・Cmd+O のファイル選択画面がポップアップより前に出る・
  閉じた後にポップアップがキーを取り戻す・隠して出し直したときにフォーカスとカーソル位置が戻る・出すときのフェードインが終わって不透明になっている
  タブと分割（1 行目の見出し・Cmd+N・Cmd+1・Ctrl+Tab・Cmd+Opt+←→（端で反対の端に戻る）・分割で同じ文書が開く・分割を戻してもタブが残る・言語の選択・最後のタブがファイル・中身のあるメモなら空のメモが出てウィンドウは残る・空のメモを閉じるとウィンドウが隠れて空のメモが 1 枚残る）・
  タブのドラッグ（同じタブバーで並べ替え・分割していないときエディタの右半分で分割・反対側のタブバーへ移す・最後の 1 枚を移すと分割が閉じる・
  動かさずに離せばただのクリック・同じ場所へ落としても変わらない）。マウスも `NSEvent` を作って `NSApp.sendEvent` に流す（WKWebView を通る経路は本物と同じ）・
  ステータスバーの版の表示（dev 版は「dev」で押せない・新しい版があると「vX.Y.Z に更新」・押すとポップアップを隠して `check_for_updates` が届く）・
  ウィンドウの位置と大きさ（掴める場所がタブの右の空きだけ・大きさを変えると送り直される・動かしたら `window.json` に覚えて出し直すと同じ場所・
  動かしてすぐ隠しても覚える・はみ出す場所は画面に収める・メニューとステータスバーのボタンの「元に戻す」で既定に戻る・隠れているときに戻すと既定の場所で出す）。
  人の操作は `setFrame` で代わりにしている（実際に掴んで動かす `performDrag` は通らない）・
  左 Shift のダブルタップ（出す・隠す・他のキーで取り消し・遅すぎ・右 Shift）。ダブルタップは、監視から届いたイベントと同じ入口（`ShiftTapMonitor.feed`）に流す
  保存（メモを Cmd+S・上書き・CRLF を保つ）・外での書き換え（変更が無ければ読み直す・あれば聞く・同じ書き換えは 2 度聞かない）・
  未保存の変更があるファイルの Cmd+W（キャンセル・保存しない）・セッションの書き出し。保存ダイアログだけは飛ばす（`savePathOverride`）
  ファイルを開く（Cmd+O・Cmd+P のあいまい検索・memode:// で記号入りのパス・無いパス・ディレクトリの登録・相対パスは無視）。ファイル選択だけは飛ばす（`openPathOverride`）。
  Cmd+P の一覧は偽のホームに「入るもの（Dropbox・深い隠しディレクトリ・git の未コミット）」と「入らないもの（OrbStack・Library・
  ホーム直下の隠しディレクトリ・node_modules・.gitignore・.ssh）」を作って確かめる
  mycast への受け渡し（`handoff_*`）: 動いている別のアプリ（ふつうは Finder）を mycast とみなして前面にし、元のアプリを前面に戻してから
  `memode-dev://focus`・`paste` を Launch Services 経由（前面にしない開き方）で自分に送る。貸している間一度も隠れない・key に戻る・ペーストボードの文字列が入る・
  3 つ目のアプリが前面になったら隠れる・mycast のパネルが無いまま 2.5 秒で隠れる。**途中で Finder ともう 1 つのアプリが前面に出る**（元のアプリ・Finder 以外の
  ふつうのアプリが 1 つは動いている必要がある。無ければ `handoff_setup NG`）
- 日本語入力（IME）・全画面アプリの上に出るか・実際のキーボードからのダブルタップ・外のクリックで隠れるか・
  タブバーの空きを実際に掴んで動かせるか（タブの上を押したらタブが切り替わるか）は、自走では確かめられない。人が試す

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

## 古いデータの置き場からの移行

`--data-dir` を付けずに起動したときだけ、`~/Memode-dev`（常用版は `~/Memode Data`）を `~/Library/Application Support/Memode-dev`（`Memode`）へ移す。
移す処理そのものはユニットテスト（`DataMigrationTests`）で見ている。実際のアプリで通すときは、古い置き場を作って 2 回起動する。

```sh
N="$HOME/Library/Application Support/Memode-dev"; L=~/Library/Logs/memode-dev/memode.log
mise run stop; [ -e "$N" ] && mv "$N" ~/Memode-dev   # 既に移っていたら古い置き場に戻す（中身はそのまま）
for run in 1 2; do mise run stop >/dev/null; : > "$L"; open -g build/Build/Products/Debug/Memode-dev.app
  for i in $(seq 1 30); do grep -q app.data_dir "$L" && break; sleep 0.5; done
  echo "== $run"; grep -E 'app\.data_(migrate|dir)|session\.loaded' "$L"; done; mise run stop
```

1 回目に `app.data_migrate moved ...` と `session.loaded docs=N`（移す前と同じ数）、2 回目は `app.data_migrate` が出ずに同じ置き場を読めば通っている。

## mycast との受け渡し（実物の mycast と）

⌃L で mycast（`~/mycast`）を開いて閉じたとき、memode にキー入力が返るか。mycast の dev 版の検証フック（フォーカスを奪わない）で、
「memode が出ているかの判定」と「Esc で `focus` が届く」までは確かめられる。貼り付けの Enter はフックで撃てないので人が試す。

```sh
cd ~/mycast && mise run run; cd -        # /Applications/mycast Dev.app を入れて起動
D=$(mktemp -d); mkdir -p "$D/home"; ML=~/Library/Logs/memode-dev/memode.log; CL=~/Library/Logs/mycast/mycast-dev.log
mise run stop; open -g build/Build/Products/Debug/Memode-dev.app --args --data-dir "$D" --index-home "$D/home"; sleep 3
B="/Applications/mycast Dev.app/Contents/MacOS/mycast Dev"
"$B" --show root --hide; sleep 1; grep 'panel.shown' "$CL" | tail -1      # 隠れているとき return_to=-（メニューバーのアイテムは数えない）
open -g "memode-dev://show"; sleep 1.5
"$B" --show root --key escape; sleep 2.5
grep -E 'panel.shown|handoff' "$CL" | tail -2   # return_to=memode-dev・handoff.sent url=memode-dev://focus
grep -E 'url.open|panel.show' "$ML" | tail -2   # url.open memode-dev://focus → panel.show
osascript -e 'quit app "mycast Dev"'; mise run stop
```

人が試すもの（常用版どうし、または dev 版どうし。dev 版で試すときは常用版の memode を止める。左 Shift のダブルタップで両方出る）:

- memode で入力中に ⌃L（dev は ⌃⌥L）→ `c` → 履歴で Enter → memode のカーソル位置に入る。memode は隠れない。ログに `panel.lend` → `panel.lend_end reason=paste` → `panel.paste focused=true sent=true`
- ⌃L → Esc / ⌃L 再押下 / ⌘Enter → memode にそのまま打てる（`lend_end reason=focus`）
- ⌃L → 他のアプリをクリック → memode も隠れる（`lend_end reason=other_app:…`）。元のアプリをクリックしたときは 2.5 秒後に隠れる（`reason=timeout`）
- ⌃L を開いたまま memode のパネルをクリック → memode に打てる（`reason=key`）
- 絵文字（⌃⌘Space）から貼っても同じ。memode を出していないときの ⌃L は今まで通り元のアプリに貼る
- 日本語入力のまま ⌃L → 貼ったあと memode の入力ソースが日本語に戻っている

## ログイン時に起動

`--selftest-login-item` で、dev 版を一瞬だけログイン項目に入れてすぐ外す（`--selftest` に入れていないのは、そのたびに
「ログイン項目が追加されました」の通知が出るため）。初回の起動で一度だけ ON にする判定はユニットテスト（`LoginItemTests`）で見ている。

```sh
L=~/Library/Logs/memode-dev/memode.log; mise run stop; : > "$L"
open -g build/Build/Products/Debug/Memode-dev.app --args --selftest-login-item --data-dir "$(mktemp -d)"
for i in $(seq 1 30); do grep -q selftest.login_item "$L" && break; sleep 0.5; done; grep login_item "$L"
```

`selftest.login_item OK before=disabled on=enabled off=disabled` が出れば通っている。外したあとも `sfltool dumpbtm` には
`Memode-dev ... Disposition: [disabled, ...]` の行が残るが、disabled ならログイン時には起動しない。

## memode コマンド

dev 版を使い捨てのデータの置き場所で起動しておき、`--dev` で流す（付けないと常用版が起動する）。

```sh
D=$(mktemp -d); mkdir -p "$D/work"; printf 'x\n' > "$D/work/日本語 #メモ & q?.txt"
open -g build/Build/Products/Debug/Memode-dev.app --args --data-dir "$D"; sleep 2.5
(cd "$D/work" && ~/memode/scripts/memode --dev "日本語 #メモ & q?.txt" "まだ無い.md")
grep -E 'url.open|file\.(opened|open_new|open_failed)' ~/Library/Logs/memode-dev/memode.log
```

`file.opened ...日本語 #メモ & q?.txt` と `file.open_new ...まだ無い.md` が出れば通っている。

## Finder から開く（file:// で届く経路）

`open -b` は Finder のダブルクリックと同じく file:// の URL で渡す。既定のアプリを変えずに確かめられる。

```sh
D=$(mktemp -d); printf '# x\n' > "$D/a.md"; printf '{}\n' > "$D/b.json"
open -g build/Build/Products/Debug/Memode-dev.app --args --data-dir "$D"; sleep 2.5
open -b local.nyshk97.memode.dev "$D/a.md" "$D/b.json"; sleep 1
grep -E 'file\.(open_from_finder|opened)' ~/Library/Logs/memode-dev/memode.log | tail -3
```

`file.opened` が 2 件出れば通っている（`url.open file://...` だけで止まっていたら file:// を memode:// と同じ扱いにしている）。
既定のアプリの切り替え（duti）は macOS が確認を挟み、Claude Code から叩くと `userCanceledErr` で黙って失敗する。自分のターミナルで叩く。

## ユニットテスト

```sh
mise run test   # ダブルタップの判定・隠す決まり・ファイルの読み書き（BOM・CRLF・UTF-8 以外・バイナリ・外での書き換え）・フォルダの一覧（git / 走査）・ウィンドウの位置（画面に収める・画面の並びの変更・window.json）
```

アプリを起動しないので、dev 版が動いていても回せる。

## 見た目の確認（スクリーンショット）

`--demo` を付けると、タブを 3 枚開いて左右に分割した状態で出る（`--show` なら空のメモ 1 枚）。
`--demo --demo-drag line`（または `area`）を足すと、左のタブを掴んで右のタブの間（area なら右のエディタ）まで動かしたところで止まる
（掴んだタブの写しと落とし先の目印を撮るため。終わったら `mise run stop`）。

```sh
open -g build/Build/Products/Debug/Memode-dev.app --args --demo; sleep 3
WID=$(osascript -l JavaScript -e 'ObjC.import("CoreGraphics"); const l=ObjC.deepUnwrap(ObjC.castRefToObject($.CGWindowListCopyWindowInfo(1,0))); const w=l.filter(x=>x.kCGWindowOwnerName==="Memode-dev" && x.kCGWindowLayer>0 && x.kCGWindowBounds.Height>200)[0]; w? String(w.kCGWindowNumber):""')
screencapture -x -o -l "$WID" /tmp/memode-panel.png; mise run stop
```

### 半透明の見え方（後ろを決めて撮る）

パネルの下地は NSVisualEffectView なので、上の `screencapture -l`（ウィンドウだけ）では後ろが合成されず、ぼかしが**ただの灰色に写る**
（素材を変えても全部同じ絵になる）。`scripts/backdrop-shot.swift` がパネルの真後ろに色付きの絵を出してから画面の領域ごと撮る。
ライトは `-NSRequiresAquaSystemAppearance YES` でアプリだけライトにして撮れる（システムの設定は変えない）。

```sh
swiftc -O -o /tmp/backdrop-shot scripts/backdrop-shot.swift
D=$(mktemp -d); mkdir -p "$D/home"; mise run stop
open -g build/Build/Products/Debug/Memode-dev.app --args --demo --data-dir "$D" --index-home "$D/home"; sleep 4
B=$(osascript -l JavaScript -e 'ObjC.import("CoreGraphics"); const w = ObjC.deepUnwrap(ObjC.castRefToObject($.CGWindowListCopyWindowInfo(1, 0))); const b = w.filter(x => x.kCGWindowOwnerName === "Memode-dev" && x.kCGWindowBounds.Height > 200)[0].kCGWindowBounds; [b.X, b.Y, b.Width, b.Height].join(" ")')
/tmp/backdrop-shot ${=B} /tmp/memode-glass.png        # 末尾に busy を付けると色の縞（読みやすさの限界）
mise run stop
```

- 枠（タブバー・ステータスバーのあたり）に後ろの色が透け、板（エディタ）の上の文字がはっきり読めれば OK

### 変換中の文字が二重にならないか（ブラウザで代わりに）

変換中は Monaco が IME の入力欄（textarea）を本文の上に重ね、未確定の文字を両方に描く。エディタの背景が透明なので、入力欄が文字を描くと二重になって滲む
（`style.css` の `.inputarea.ime-input` で入力欄の文字を消している）。日本語入力は自走で打てないので、ビルドした `web/dist/editor` を Chromium で開いて構造だけ確かめる。
Chromium は EditContext があると textarea を使わない（WKWebView とは別の経路になる）ので、初期スクリプトで消す。
CDP の `Input.imeSetComposition` は黄色の背景を塗って見比べられないので、変換のイベントを textarea に合成して送る。

```sh
(cd web/dist/editor && python3 -m http.server 8765 >/dev/null 2>&1 &); echo 'delete window.EditContext;' > /tmp/noec.js
ab() { agent-browser --session ime "$@"; }
ab --init-script /tmp/noec.js open "http://localhost:8765/index.html?v=$(date +%s)"; ab wait --fn '!!document.querySelector(".monaco-editor .view-lines")'
ab eval '(() => { document.querySelector(".monaco-editor textarea").focus(); return document.querySelector(".monaco-editor textarea").className })()'  # inputarea ... なら textarea の経路
ab keyboard type "abc "
ab eval '(() => { const ta = document.querySelector(".monaco-editor textarea"), b = ta.value; ta.dispatchEvent(new CompositionEvent("compositionstart", { data: "" })); for (const s of ["に", "にし", "にしむ", "にしむら"]) { ta.value = b + s; ta.setSelectionRange(ta.value.length, ta.value.length); ta.dispatchEvent(new CompositionEvent("compositionupdate", { data: s })); ta.dispatchEvent(new InputEvent("input", { data: s, inputType: "insertCompositionText", isComposing: true })); } return ta.className })()'
ab eval '(() => { const s = document.createElement("style"); s.textContent = ".monaco-editor .view-lines { opacity: 0 !important }"; document.head.append(s); return 1 })()'  # 本文だけ隠す
ab screenshot /tmp/memode-ime.png; ab close; pkill -f "http.server 8765"
```

- 2 つ目の eval が `... ime-input` を返し（変換中の表示になっている）、本文を隠したスクショで「にしむら」が消えてキャレットだけ残れば OK（入力欄が文字を描いていない）。
  修正前は本文を隠しても入力欄側の文字が残っていた
- 実際の IME で変換中の下線が出るか・滲まないかは、dev 版で人が確かめる

## 配布物（公証の手前まで）

```sh
mise run release:zip   # Release ビルド → Sparkle の中身を内側から署名し直す → 署名・Hardened Runtime・timestamp・SUFeedURL を検証 → zip
```

`OK: dist/Memode-<version>.zip` で通っている。dev 版に配信先が入っていないことも見る:
`PlistBuddy -c 'Print :SUFeedURL' build/Build/Products/Debug/Memode-dev.app/Contents/Info.plist` が空。

## ビルド成果物の確認

- 署名: `codesign -dvv build/Build/Products/Debug/Memode-dev.app 2>&1 | grep Authority` が `Apple Development` であること（ad-hoc だとアクセシビリティの許可がリビルドのたびに外れる）
- Info.plist: `PlistBuddy -c 'Print :CFBundleURLTypes:0:CFBundleURLSchemes:0'` が dev 版では `memode-dev`
- Web のビルドが入っているか: `ls build/Build/Products/Debug/Memode-dev.app/Contents/Resources/editor`
