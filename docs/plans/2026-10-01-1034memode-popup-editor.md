# memode: ショートカットで出し入れするポップアップ型エディタ

## 概要・やりたいこと

今 Cursor でやっている次の 2 つを、軽いポップアップのエディタで置き換える。

- Cmd+N で新規タブを作ってメモを書く（基本は使い捨て。ときどきパスを決めて保存する）
- 既存のファイルを開いて中身を見る。ときどき編集する

Cursor の AI 機能・チャット・ターミナルはほぼ使っていないので、要るのは「エディタとしての手触り」と「すぐ出せて、すぐ消せる」こと。

- **左 Shift のダブルタップ**で画面中央にポップアップを出し、同じ操作で隠す。隠しても状態は保ち、次に出したときは続きから編集できる
- 主要言語のシンタックスハイライト
- 同時に複数タブ（5〜6 枚で足りる）。必要なときは左右に分割
- VS Code と同じキー操作: Cmd+Opt+↑↓ でカーソルを上下に増やす、Opt+↑↓ で行の移動
- サイズは 15" MacBook の画面の約 8 割。大きいディスプレイでは 8 割にせず、同じくらいの大きさで止める

## 前提・わかっていること

### 決めたこと（/dig-lite）

- **構成: アプリの外枠は Swift（AppKit）、エディタ部分は WKWebView の中の Monaco**
  - Swift 側: ポップアップ（NSPanel）、左 Shift ダブルタップの検知、ファイルの読み書き、セッションの保存、メニューバー常駐
  - Web 側: Monaco、タブ、分割、Cmd+P の候補 UI
  - **Monaco は最初に日本語入力を確かめる（Phase 2）。だめなら CodeMirror 6 に替える**。替えても Swift 側と、Swift と JS の間の受け渡しはそのまま使えるように、エディタ部分を差し替えられる境界で作る
  - 却下した案
    - CodeEditSourceEditor: README に「本番利用にはまだ早い」とあり、日本語入力の不具合報告も続いている
    - STTextView: 複数カーソルが作り途中・行移動なし・TextKit 2 の変換まわりのバグがある
    - Electron: Shift 単体のダブルタップを拾うのにネイティブモジュールが要り、常駐の負荷も大きい
- **見せ方: ポップアップ**（ランチャーモードにはしない）。Dock に出さず（`LSUIElement`）、メニューバーに常駐する
- **使い捨てメモ（未保存タブ）: タブを閉じるまで残す**（VS Code の hot exit と同じ）。アプリを再起動しても戻り、タブを閉じたら確認なしで消える。残したいものはパスを決めて保存する。**保存済みファイルへの未保存の変更も同じく残す**（1回目で決定）
- **既存ファイルの開き方は 4 つとも用意する**: Cmd+O（macOS のファイル選択画面）・Cmd+P（最近使ったファイル＋登録フォルダ内をあいまい検索）・ターミナルの `memode <path>`・登録フォルダ（Cmd+P の検索対象に入れる）

### こちらで決めた細部（違えば実装前に直す）

- **サイズ**: 幅 `min(画面の 80%, 1400pt)`・高さ `min(画面の 80%, 900pt)`（基準は `visibleFrame`。メニューバーと Dock を除いた領域）。上限の値は実機で見て調整する。**出す画面はマウスがある画面**（`NSScreen.main` は常駐アプリだと当てにならないので、`NSEvent.mouseLocation` を含む画面を探す）。内蔵 1 枚のときと、内蔵＋Studio Display の 2 枚のときの両方で確かめる
- **隠す操作**: 左 Shift のダブルタップと、ポップアップの外をクリックしたとき。外かどうかは「フォーカスが自分のアプリの外に移ったか」で判定し、**自分のアプリのダイアログ（ファイル選択・保存・確認・シート）にフォーカスが移ったときは隠さない**（`resignKey` だけで判定すると、Cmd+O や Cmd+S のたびに隠れる）。判定のしかたはパネルのスタイル（Phase 2 で決める）に合わせる。Esc は Monaco の複数カーソル解除などに使うので割り当てない。**左 Shift のダブルタップで隠したときだけ**、直前に使っていたアプリにフォーカスを戻す（外のクリックで隠したときは、クリックした先のアプリにフォーカスが移っているので何もしない）
- **ダブルタップの判定**: 左 Shift（keyCode 56 とデバイスごとのフラグで左右を見分ける）の「押す→離す」が 2 回。しきい値は 2 つ: 1 回の押しの長さ（長押しは除く）と、1 回目に離してから 2 回目に押すまでの間隔（どちらも ~300ms から実機で調整）。その間に他のキーや修飾キーが入ったら取り消す（大文字を打つときの Shift で誤発火させない）。右 Shift には反応しない
- **App Sandbox は使わない**（Hardened Runtime は使う）。任意のパスを開き、`git ls-files` を叩くため
- **データの置き場**: セッション（タブ・未保存の中身・カーソル位置・分割の状態）・最近使ったファイル・登録フォルダ・設定を JSON で置く。**dev 版と常用版でデータを分ける**（作りかけの dev が常用版のメモを書き潰すと戻せないため）。置き場所は `~/Library/Application Support/` の下（常用版は `Memode/`、dev 版は `Memode-dev/`）。どれもアプリが書くファイルなのでホームの直下に置かない（Cmd+P の一覧にも出ない）。Finder で見たいときはメニューバーの「データのフォルダを開く」。`~/Documents` は TCC で保護されていて自走の検証で読めないので避ける。ログも同じく dev 版と常用版で分ける
- **Monaco はアプリに同梱する**（CDN から読まない。オフラインでも動き、版を固定できる）。`web/` を Vite + TypeScript で作り、ビルドしたものを `.app` の Resources に入れる。読み込みは独自の URL スキーム（`WKURLSchemeHandler`）で行う（`file://` では Monaco の worker が動かないため）
- **アプリのショートカット（Cmd+N・W・O・P・S・Shift+S・Cmd+1〜9・Ctrl+Tab・Cmd+\）はネイティブのメニューに置く**。`LSUIElement` のアプリにはメインメニューが標準で作られないので、`NSApp.mainMenu` をコードで組む（画面には出ない）。そこに標準の編集メニュー（Cut・Copy・Paste・Select All）も入れる（無いと WKWebView で Cmd+C・V・X・A が効かない）。WKWebView はキーをまず Web 側に渡し、JS が処理しなかったものをメニューに戻すので、Monaco 側でこれらのキーを使わないようにしておく。Phase 2 ではこれで成り立つかを確かめる
- 自作 Mac アプリの型（`~/Library/CloudStorage/Dropbox/dotfiles/.claude/references/personal-mac-apps.md`）に従う: dev 版と常用版の分離（表示名・bundle id・アイコン）・署名 ID の自動解決（**public リポジトリなので、署名のハッシュ・Team ID は gitignore した `*.local.xcconfig` に逃がす**）・バージョンの管理を 1 箇所に・ログ・dev 版だけの検証用起動引数・Sparkle・mise タスク
- 環境（2026-10-01 時点）: macOS 26.6.2 / Xcode 27.0 / xcodegen・node 24 は mise で入っている。このマシンは個人 PC（`tsubasanoMacBook-Air-4`）

## 実装計画

### 事前準備 [人間👨‍💻]
- なし（権限の付与・日本語入力の確認は、そこまで進んだ時点でお願いする）

### Phase 1: プロジェクトの土台 [AI🤖]
- [x] `.gitignore`（`*.xcodeproj`・`build/`・`*.local.xcconfig`・`web/node_modules`・同梱する Monaco のビルド成果物）
- [x] XcodeGen の `project.yml`（`schemes:` を明示）。Debug = `Memode-dev` / `local.nyshk97.memode.dev`、Release = `Memode` / `local.nyshk97.memode`。`LSUIElement = YES`。URL スキームも Debug は `memode-dev`、Release は `memode` に分ける（ビルド設定から Info.plist の `CFBundleURLTypes` に流す）
- [x] 署名 ID を keychain から引いて `signing-*.local.xcconfig` に書き出すスクリプト（`~/keyrc/scripts/gen-signing-xcconfig.sh` が見本）。証明書が無ければ ad-hoc にして警告を出す。**ad-hoc だとビルドのたびにアクセシビリティの許可が外れるので、その状態では Phase 3 以降に進まない**
- [x] バージョンは `MARKETING_VERSION` の 1 箇所で管理し、`CURRENT_PROJECT_VERSION` と Info.plist の 2 つのキーに流す
- [x] ログ（`~/Library/Logs/memode/` と `memode-dev/`。イベント名は固定の文字列）
- [x] `.mise.toml`: `gen` / `build` / `start` / `stop` / `web:build`（description は日本語）。`build` と `start` は `web:build`（`npm ci` 込み）に依存させる。Xcode のビルドでは node を呼ばず、Web のビルド成果物が無ければ失敗させるだけにする
- [x] リポジトリの `CLAUDE.md`（構成・決めたこと・ビルドと検証の入口）
- [x] メニューバーのアイコンとメニュー（表示・About・終了）だけのアプリがビルド・起動できるところまで

### Phase 2: 最小のポップアップ + Monaco と、日本語入力の確認 [AI🤖]
- [x] 最小の NSPanel を、メニューバーのメニューと dev 版の起動引数 `--show` で出し入れできるようにする。Monaco は最初からこのパネルの中に置く（IME・キーの届き方・フォーカスはウィンドウの種類で変わるので、普通のウィンドウで確かめても意味がない）。パネルのスタイル（nonactivating にするか、普通にアプリをアクティブにするか）は、dev 版の起動引数で切り替えられるようにする
- [x] `web/`（Vite + TS）で Monaco を 1 枚表示するだけのページ。`monaco-editor` の版は lockfile で固定する
- [x] 独自の URL スキームでページを読み込み、worker が動く（シンタックスハイライトが付く）ことを確かめる
- [x] Swift と JS の受け渡しの土台（`WKScriptMessageHandler` と `evaluateJavaScript`）。JS の準備ができる前に来た要求（セッションの復元、起動直後の `memode <path>`）は Swift 側でためておき、JS から準備完了の通知が来てから流す。dev 版だけ、JS で「中身・カーソルの数・行」を取って返せるようにし、自走の検証に使う
- [x] 自走で確かめる: Cmd+Opt+↑↓ でカーソルが増える／Opt+↑↓ で行が動く（dev 版のアプリの中で `NSEvent.keyEvent` を作って `NSApp.sendEvent` に流す。アクセシビリティの許可が要らず、メニューへの経路も通る。カーソル数と中身で判定する）／Cmd+N・W・O・P・S がメニューに届く／Cmd+C・V・X・A がエディタで効く
- [x] パネルの 2 つのスタイルを、自走で見られる項目（メニューのショートカット・NSOpenPanel が前に出るか。重なり順は `CGWindowListCopyWindowInfo` で許可なしに取れる）で比べて候補を絞る。全画面アプリの上に出るかは自走では確かめにくいので、人間の確認で見る。最終的に決めるのは、IME を見た後の「Phase 2 の確認」。両方が全部を満たせないときの優先順は **IME ＞ ショートカットとダイアログが正しく動く ＞ 全画面アプリの上に出る**（2回目で決定）。結果はログに書く
- [x] パネルを隠して出し直したとき、エディタにフォーカスとカーソル位置が戻る

### Phase 2 の確認 [人間👨‍💻]
- [x] dev 版のパネルで、2 つのスタイルの両方で日本語入力を試す: 変換・確定・**変換中の Enter**・変換中の Backspace・複数カーソルでの日本語入力・ライブ変換・使っている IME（標準 or Google 日本語入力）で。あわせて、全画面アプリの上に出るかも両方のスタイルで見る
- [x] 結果で決める: どちらかのスタイルで問題なし → そのスタイルと Monaco で進む。**2 つのスタイルのどちらでも致命的な問題があるときだけ** CodeMirror 6 に替えて Phase 2 をやり直す（ログ > 方針変更 に記録する）。**合格の線は「Cursor（VS Code）で今できていることができること」**。複数カーソルでの日本語入力は VS Code でも主カーソルにしか入らないので、そこまでなら許す（1回目で決定）

### Phase 3 の前に [人間👨‍💻]
- [x] 初めて起動したときのダイアログから、dev 版にアクセシビリティ（必要なら入力監視）の許可を出す（グローバルな `flagsChanged` / `keyDown` を拾うのに要る）

### Phase 3: 左 Shift のダブルタップと、ポップアップの仕上げ [AI🤖]
- [x] Phase 2 の NSPanel を、マウスがある画面の中央に、上で決めたサイズで出す。Space をまたいでも出る（`[.canJoinAllSpaces, .fullScreenAuxiliary]`。`.moveToActiveSpace` と同時に指定すると例外になる）
- [x] グローバルとローカルのイベント監視を両方登録し、左 Shift のダブルタップを検知する。判定はキーの並びを受け取る純粋な関数に切り出してユニットテストする（他のキーが挟まる・右 Shift・間隔オーバー・Shift の長押し）。隠す条件の判定にも「自分のダイアログにフォーカスが移ったときは隠さない」のケースと、隠すきっかけごとのフォーカスの戻し先の期待値を入れる
- [x] 同じ操作・外のクリックで隠す（`orderOut`。WKWebView はそのまま残すので状態も残る）。フォーカスを戻すのはダブルタップで隠したときだけ
- [ ] dev 版だけの起動引数 `--snapshot <png>`（表示が済んだらパネルを画像にして保存）
- [ ] 内蔵 1 枚と、内蔵＋Studio Display の 2 枚でのサイズと位置（2 枚の環境は下の「Phase 3 の確認」で）

### Phase 3 の確認 [人間👨‍💻]
- [ ] Studio Display をつないだ状態で、サイズと位置・マウスがある画面に出るか・全画面アプリの上に出るか

### Phase 4: タブと左右分割 [AI🤖]
- [x] タブバー: Cmd+N（新しい未保存タブ）・Cmd+W（閉じる。未保存のメモは確認なしで消える。**保存済みファイルに未保存の変更がある場合だけ確認する**）・Cmd+1〜9・Ctrl+Tab
- [x] 左右分割（Cmd+\）。同じファイルを両側で開いたら、Monaco の同じ model を共有して中身を同期させる
- [x] 言語の判定（拡張子から）。未保存タブは plaintext で始め、手で言語を切り替えられる（ステータスバーかコマンドで）
- [x] ダーク／ライトはシステムの設定に合わせる

### Phase 5: 保存とセッションの復元 [AI🤖]
- [x] セッション（タブ・未保存の中身・カーソル・スクロール・分割の状態・ファイルを読んだときの mtime とハッシュ）を変更のたびに保存する（数百 ms で間引く）。ポップアップを隠したときは即座に保存し、アプリの終了時は保存が終わるまで終了を待たせる（JS から中身を取るのは非同期なので、待たないと最後の変更が消える）。待つのは数秒までにし、時間切れなら最後にディスクへ保存したセッションのまま終了して、ログに残す。書き込みは一時ファイルに書いてから置き換え、途中で落ちても壊れないようにする
- [x] 起動時に復元する。保存済みファイルの未保存の変更を戻すときは、ディスク上のファイルが止めている間に書き換わっていないか比べ、書き換わっていたら次の項目と同じく知らせて選ばせる。**JSON が壊れていたら捨てずに退避して空で起動**し、ログに残す
- [x] Cmd+S: 未保存タブは保存ダイアログ、既存ファイルは上書き。Cmd+Shift+S で別名で保存
- [x] 開いているファイルが外で書き換わったら: 未変更のタブは読み直す。変更中のタブは知らせて選ばせる（ポップアップを出したときにまとめて確かめる）
- [x] 検証: 中身を入れた状態でアプリを kill → 起動して戻ることを確かめる。壊れた JSON を置いて起動する

### Phase 6: ファイルを開く導線 [AI🤖]
- [x] Cmd+O: NSOpenPanel。開いたら最近使ったファイルに入れる
- [x] フォルダの登録と解除（メニューから）
- [x] Cmd+P: 最近使ったファイル＋登録フォルダ内のファイルをあいまい検索する。git のリポジトリなら `git ls-files` で一覧を取り、そうでなければ件数と深さに上限を付けて走査する（`node_modules` 等は除く）
- [x] `memode <path>` コマンド: 相対パスを `$PWD` とつないで絶対パスにし（存在しないパスでも動くように `realpath` は使わない）、独自の URL スキーム（`memode://open?path=...`、dev 版は `memode-dev://`。`memode --dev` で切り替える）を `open -b <bundle id> '<URL>'` で開くシェルスクリプトを入れる（bundle id も指定するのは、古いビルドの `.app` が開かないようにするため）。パスの percent-encode は `osascript -l JavaScript` の `encodeURIComponent` で行い、アプリ側は `URLComponents` の `queryItems` で取り出す（空白・日本語・`#`・`&` を含むパスで確かめる）。`open -b <bundle id> <path>` は存在しないパスだとエラーになり、アプリまで届かないので使わない（置き場所と PATH への入れ方は実装時に決める）。アプリは `application(_:open:)` で URL を受けてポップアップを出す。すでに開いているファイルならそのタブに切り替える。存在しないパスは新しいファイルとして開き、保存したときに作る（`code newfile.md` と同じ）。ディレクトリなら確認を挟んでから登録フォルダに入れて Cmd+P を開く（1回目で決定。URL スキームはブラウザのリンクからも叩けるので、黙って登録しない）
- [x] 大きすぎるファイル・バイナリ・UTF-8 として読めないファイルは開かずに知らせる（上限は実装時に決める）。BOM と改行コード（CRLF）は読んだときのものを保って書き戻す

### Phase 7: 配布と常用版 [AI🤖]
- [x] アイコン（dev 版は「DEV」の印付き）
- [x] Sparkle（常駐して存在を忘れる系なので、自動チェックを ON）。dev 版には `SUFeedURL` を入れない
- [x] 配信用のリポジトリ `memode-releases`、`docs/CHANGELOG.md`、`scripts/changelog.py`、`build.sh`（`--skip-notarize` 付き）、`release.sh`、`mise run release`。手順は personal-mac-apps.md の「リリース」に従う
- [x] `nyshk97/tap` に cask を足し、Brewfile に `cask 'nyshk97/tap/memode'` を足す
- [x] `VERIFY.md` に、ここまでで通った検証の手順を書く

### 動作確認 [人間👨‍💻]
- [ ] 常用版で数日使ってみる: メモを書く・Cmd+P でファイルを開く・`memode <path>`・分割・再起動後の復元・内蔵 1 枚と 2 枚の両方
- [ ] 気になったところを挙げてもらい、次の計画に回す

## ログ
### 試したこと・わかったこと
- Monaco 0.57 は `editor.main.js` から言語サービス（TS・JSON・CSS・HTML）と LSP クライアントを除いた import を `web/scripts/gen-monaco-entry.mjs` で作って読む。シンタックスハイライト（Monarch）は 80 言語以上が入り、worker はエディタ本体の 1 種類だけで済む。ビルド後の大きさは約 4.9MB
- 左 Shift のダブルタップ（Phase 3）: 判定は `DoubleTapDetector`（ユニットテスト 12 件。判定をわざと壊すと `testOtherKeyInBetweenCancels`・`testRightShiftIgnored` が落ちることも確認）。dev 版の `--selftest` では、監視から届いたイベントと同じ入口（`ShiftTapMonitor.feed`）に合成した flagsChanged を流し、出す・隠す・他のキーで取り消し・遅すぎ・右 Shift の 5 項目が nonactivating で通った（26/26）。グローバルな監視に実際のキーが届くことは、ユーザーが実機で確認済み（2026-10-01。「表示/非表示、良さそう」）
- 自走の検証で未来の時刻を付けて Shift を流すと、判定の途中の状態が次のシナリオに残って誤って成立した（`double_tap_too_slow NG`）。selftest 側でシナリオごとに状態を戻して解消。実際のキー入力では時刻が未来にならないので起きない
- activating スタイルの selftest は、ユーザーがシステム設定で許可を操作している最中に回したため、フォーカスを取り合って 6 項目が NG になった（パネルが key を失う）。nonactivating では起きない種類の問題で、activating を選ぶならユーザーが操作していないときに回し直す
- タブと分割（Phase 4）: dev 版の `--selftest` で 8 項目（1 行目の見出し・Cmd+N・Cmd+1・Ctrl+Tab・分割で同じ文書が開き文書は増えない・分割を戻してもタブが残る・言語の選択・全部閉じると空のメモが 1 枚）が通った（34/34）。`--demo` で開いた状態のスクリーンショットも確認した
- 保存とセッション（Phase 5）: `--selftest`（46/46）と `--selftest-restore`（5/5）が通った。kill -9 の後も session.json に直前の書き換えが残り、起動し直すと 3 枚のタブが戻る。壊れた session.json は `session.broken-<日時>.json` に退避して空で起動する。ユニットテストは FileIO の 4 件を足して 16 件
- **終了の待ち合わせが止まった**: 自走の検証は `Task { @MainActor in ... NSApp.terminate(nil) }` から終了するので、AppKit が `.terminateLater` の返事を待つ間、main キューに積んだ「書き終わった」とタイムアウトが動かず、アプリが終わらなかった（修正前は `selftest.done` の後に `app.terminate` が出ず、プロセスが残った）。Sparkle など main キューから終了を呼ぶものでも同じことが起きうるので、タイムアウトは `Timer` を `RunLoop.main` の `.common` に、書き終わりの知らせは `RunLoop.main.perform(inModes: [.common])` に載せて解消（`app.terminate flushed`）
- Cmd+O（Phase 6 の先取り）: ユーザーから「保存はできるけど Cmd+O で開けない」と報告（Phase 5 の時点では選択画面を出すだけだった）。開く処理を入れ、`--selftest` に 4 項目（空のメモを置き換えて開く・同じファイルは切り替えるだけ・UTF-8 以外は理由を出す・最近使ったファイルに入る）を足して 50/50。最近使ったファイルは `<データ>/recent.json`（100 件まで）
- `mise run stop` は pkill（SIGTERM）だと終了時のセッションの書き出しを通らないので、`osascript -e 'quit app "Memode-dev"'` で終わらせ、終わらなければ kill にした（`app.terminate flushed` を確認）
- Phase 6: `--selftest` に 11 項目（Cmd+P に登録フォルダの中が出て node_modules は出ない・あいまい検索・Enter で開く・memode:// で空白と日本語と # & を含むパス・無いパスは新しいファイルで保存すると作る・ディレクトリは確認してから登録・相対パスは無視）を足して 59/59。本物の `scripts/memode --dev` からも「日本語 #メモ & q?.txt」と「まだ無い.md」を開けた。ユニットテストは FolderIndex の 2 件（走査で node_modules を飛ばす・git では .gitignore に従い untracked も出す）を足して 18 件
- **フォルダの一覧作りに 5.2 秒かかった**: アプリから初めて `/usr/bin/git`（xcrun を通す入口）を呼ぶと遅い。シェルからだと一瞬なので気づきにくい。`xcrun --find git` で本物の場所（`/Applications/Xcode.app/.../usr/bin/git`、6ms）を一度だけ調べて使うようにし、0.1 秒になった。あわせて一覧は起動時と登録時に裏で作っておき、Cmd+P では作っておいたものをすぐ出して、30 秒より古ければ裏で作り直す（1 回目のレビューで見送った「一覧を作り直すタイミング」をここで決めた）
- `memode` コマンドは `mise run install-cli` で `~/.local/bin/memode`（このリポジトリの `scripts/memode` へのリンク）に入れる。`~/.local/bin` は PATH に入っているが、ディレクトリは無かった
- ホームの下全部の一覧: 見積もりは find で 77 万件（うち ~/OrbStack が 69.6 万）。除く場所を決めて作ると 8,391 件・0.48 秒（git の .gitignore で生成物が落ちる）。初回は ~/Documents などの許可のダイアログへの返事待ちで 133 秒かかった（たどる処理が止まる）
- **除く場所の判定が狂っていた**（自走の検証で発見）: `FileManager.enumerator(at: URL)` は起点が /var/... でも /private/var/... のパスを返し、`resolvingSymlinksInPath()` は逆に /private を外すので、深さの計算が 1 ずれて OrbStack・Library/Preferences が一覧に入った（修正前は `cmd_p_home_index NG`、パスの一覧に `.../home/OrbStack/docker/big.txt`）。`enumerator(atPath:)` の相対パスでたどるようにして解消。本物のホーム（/Users/...）では起きない形だったが、たどり方に頼らない作りにした
- 一覧を作り直す間隔は、登録フォルダだけだったときの 30 秒から、ホーム全体に広げたときに 5 分（`indexTTL = 300`）に変えた
- JS には一覧をパスだけ・変わったときだけ送る（版の番号で判断。JS が一覧を持っていなければ `quickOpenResend` で送り直してもらう）
- ドロップ対策（実装のレビューで出た P1 のうち、ユーザーが入れると決めたもの）: Finder からのファイルのドロップは `EditorWebView.performDragOperation` で受けてタブで開き、エディタ以外のページへの移動は `WKNavigationDelegate` で止める。`--selftest` の `navigation_blocked`（`about:blank` への移動）は、止める処理を外した版で NG、入れた版で OK になることを確認（`file://` への移動は WebKit 自身が断るので、それで試すと止める処理を外しても通ってしまった）
- Phase 7: アイコンは `scripts/make-icon.swift`（フルブリード・dev 版は DEV の帯）。リリースのスクリプトは MenuBar Tidy の原本から。CHANGELOG の頭を原本から切り出すとき、「書き方」の例の中の `## [Unreleased]` で切ってしまい `changelog.py check` が落ちた（原本のメモにある罠そのもの）。`make-release-zip.sh` の `$FEED_URL）` は bash 3.2 の全角の罠で、検出の正規表現で見つけて `${FEED_URL}` に直した
- v0.1.0 をリリース（2026-10-01）: 公証は Accepted。`gh release download` したものが `spctl` で「Notarized Developer ID」、`stapler validate` も通り、cask の sha256 と一致。Sparkle の `sign_update` は初回に keychain の許可（SecurityAgent）が出たので、リリースの前に一度叩いて済ませた。Brewfile に `cask 'nyshk97/tap/memode'` を足して入れた（`brew bundle` は無関係の hashicorp/tap が未 trust で止まったので `brew trust hashicorp/tap`。docker-desktop の更新は sudo で失敗したが memode は入った）
- 独自の URL スキーム（`WKURLSchemeHandler`）で配った worker は動く（worker から返事が来ることで確認）。Resource Timing には worker の読み込みが載らないので、その判定には使えない
- dev 版の `--selftest`（キーは `NSEvent` を作って `NSApp.sendEvent` に流す）で、両方のスタイルとも 20 項目が全部通った（2026-10-01）。Cmd+N/P/S/Shift+S/W/1・Cmd+\ はメインメニューに届き、Cmd+A/C/X/V も効く
- **Ctrl+Tab はメインメニューのキーとしては届かなかった**（修正前の selftest で `menu_ctrl_tab NG got=(none)`）。`bridge.ts` で keydown を拾い、`action` として Swift に回すようにして通した
- Cmd+O のファイル選択画面は、ポップアップが `.floating` なので普通のウィンドウとして出すと後ろに隠れる。シート（`beginSheetModal(for: panel)`）で付けると前に出て、閉じた後もポップアップがキーを取り戻す
- activating スタイルは、`NSApp.activate()` だけだと macOS の協調型アクティベーションで断られ、パネルがキーを取れなかった（`isKeyWindow=false`、Cmd+Shift+S・Cmd+A/C/X が NG）。`activate(ignoringOtherApps: true)` にすると通る。nonactivating は前面のアプリが変わらないまま（`frontmost=PolePole->PolePole`）キー入力を受けられる

### 方針変更
- Phase 4 の「保存済みファイルに未保存の変更があるときだけ Cmd+W で確認する」は、保存済みのファイルを扱えるようになる Phase 5 で入れる（Phase 4 の時点ではタブはすべて使い捨てのメモ）。Phase 5 で入れた（保存・保存しない・キャンセル。ほかのグループでも開いているときは聞かずに閉じる）
- 自走の検証は `--data-dir <使い捨てのディレクトリ>` を必須にした（Phase 5 からタブの状態が残るので、手元の dev 版のメモを書き潰さないため）
- 外での書き換えで「自分の変更を残す」を選んだら、その書き換えについては 2 度聞かない（目印をディスクの新しい中身に合わせる）。ファイルが消えたときは、未保存の変更が無ければ中身を残して「未保存の変更あり」にする（保存すれば作り直せる）
- 起動時に前回のセッションを読めたら `session.prev.json` に控えを取る（復元に失敗して上書きしたときの保険）
- 1 回目のレビューで見送った「最後の 1 枚を閉じたときの挙動」は Phase 4 で決めた: 分割中ならそのグループごと閉じ、分割していなければ空のメモを 1 枚作る（エディタが空にならない）
- タブの見出しは、メモは 1 行目（30 文字まで）、ファイルはファイル名。1 行目に文字（かな・漢字・英数字）が無いとき（空・`{` だけ等）は「scratch」（番号は付けない）
- 分割は VS Code と同じく「グループ」が左右 2 つまで、それぞれがタブを持つ。分割を戻すと、右にしか無いタブは左へ移す（使い捨てメモの中身を消さないため）
- **Cmd+P の対象を「登録フォルダだけ」から「ホームの下全部（＋ホームの外の登録フォルダ）」に変えた**（ユーザーの希望。2026-10-01）。除く場所: ~/Library（CloudStorage＝Dropbox 等は入れる）・~/OrbStack（Docker のボリュームで 70 万ファイル近い）・~/Applications・~/Music・~/Movies・~/Pictures・ホーム直下の隠しディレクトリ・どこにあっても node_modules / build / .git / .ssh / .gnupg 等。git のリポジトリの中は `git ls-files`。登録フォルダは「ホームの外も探したいとき」のために残す
- **パネルは nonactivating、エディタは Monaco に決定**（2026-10-01）。ユーザーが nonactivating のパネルで日本語入力を試して「問題なし」。外のクリックで隠れる・Cmd+O の画面でポップアップが残ることもユーザーが確認。activating は自走の検証で前面のアプリの取り合いに弱く、隠したときにフォーカスを戻す処理も要るので選ばない（切り替えの仕組みは dev 版のメニューに残してある）
- **常用版のデータの置き場を `~/Memode/` から `~/Memode Data/` に変えた**（2026-10-01）。macOS のディスクは大文字・小文字を区別しないので、`~/Memode` がリポジトリの `~/memode` と同じフォルダになり、v0.1.0 の常用版が `session.json`・`recent.json` をリポジトリの直下に書いていた（public リポジトリなので、コミットすると手元のパスが出る）。`.gitignore` に足す案は、登録フォルダなどもリポジトリに混ざり続けるので取らない
- **データの置き場を `~/Memode Data/`・`~/Memode-dev/` から `~/Library/Application Support/Memode/`・`Memode-dev/` に変えた**（2026-10-01）。中身はどれもアプリが書くもので、ホームの直下に置く理由が「Finder で開ける」だけだった。ホームの直下が散らかり、Cmd+P の一覧に session.json などが出ていた。Finder で開く用にメニューバーへ「データのフォルダを開く」を足した。起動時に新しい置き場が無く古い置き場があればフォルダごと移す（両方あれば古い方に触らない）。Dropbox に置いて全部の Mac で共有する案は、2 台で同時に動かすと session.json を書き合って未保存のメモが消えるので取らない
- **アップデートの入口をポップアップのステータスバーにも置いた**（2026-10-01）。パネルは nonactivating なので、ポップアップを出しても上のメニューバーは前面のアプリのまま。メニューバーアイコンの「アップデートを確認…」だけだと気づきにくい。右端に今の版を出し、押すとポップアップを隠してから Sparkle の確認を出す（.floating のパネルの後ろに Sparkle の画面が隠れないように）。Sparkle が新しい版を見つけたら「vX.Y.Z に更新」に変える。⚙ のメニューを新しく作る案は、入れたいのが 1 つだけなので取らない
- **ログイン時に起動するようにした**（2026-10-01）。左 Shift のダブルタップは動いていないと効かないので、常用版は初回の起動で一度だけ `SMAppService.mainApp` に登録する（自分で OFF にしたら戻さない。一度 ON にしたことを UserDefaults に覚える）。メニューバーのメニューに「ログイン時に起動」のチェックを置く。dev 版は自動では ON にしない（常用版と一緒に立ち上がるとダブルタップに両方が反応する）。cask で LaunchAgent を置く案は、brew の外で効かずアプリから切り替えられないので取らない
- **空のメモの見出しを「無題-N」から「scratch」に変えた**（ユーザーの希望。2026-10-01）。番号は付けない: 見出しが scratch のままなのは開いたばかりの空のタブだけで、見分けるのは位置で足りる。番号を決めていた `untitledIndex` は session.json の項目ごと消した（古い session.json に残っていても読み飛ばす）。保存ダイアログの初期名も `scratch.txt`
