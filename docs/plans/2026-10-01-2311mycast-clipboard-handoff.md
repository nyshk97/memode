# memode の入力中に mycast のクリップボード履歴を使えるようにする

## 概要・やりたいこと

memode で書いている途中に ⌃L で mycast を開き、クリップボード履歴から選んで memode に貼りたい。
今は ⌃L を押した瞬間に memode が隠れ、選んだものは memode の後ろにいたアプリに貼られる。

memode（このリポジトリ）と mycast（`~/mycast`）の両方を少しずつ直す。memode は mycast に入力を「貸している」あいだ隠れずに待つ。
mycast は「開いたときに memode が出ていた」なら、閉じたあとで memode に入力を返す（貼るときは memode 自身に貼らせる）。

## 前提・わかっていること

- 原因（2026-10-01 23:04:31 のログで確認）
  - mycast: `panel.shown mode=root ... prev=local.d0ne1s.polepole`。memode は nonactivating なので、前面のアプリは後ろの PolePole のまま。
    mycast は貼り先を PolePole と覚える
  - memode: `panel.resign_key hide=true keyWindow=none` → `panel.hide reason=focusLost`。キーを失ったら隠す規則（`HideRules.shouldHideOnResignKey`）に当たる
  - したがって memode が隠れないようにするだけでは足りない（⌘V は PolePole に入る）
- mycast の作り（`~/mycast/CLAUDE.md`）
  - パネルは nonactivating だが、開くときに `NSApp.activate(ignoringOtherApps: true)` するので前面は mycast になる（ログの `front=io.github.nyshk97.mycast`）。
    Secure Event Input 中は activate が断られ、前面は元のアプリのまま key だけ取る
  - 貼り付けは `Paster`: 閉じる → 入力ソースを戻す → 元のアプリを 1 回だけ前面にして待つ → ペーストボードに書く → ⌘V を合成。この順を崩さない。
    前面になるのを待つ上限は 1.0 秒（＋前面になってから 0.05 秒置く）。上限を過ぎたらコピーだけに落とす（`Paster.waitUntilActive`）
  - 元のアプリへ戻すのは Esc / ホットキー再押下 / ⌘Enter（コピーだけ）/ Sleep・Lock のとき（`close` の `.escape, .toggle, .copied, .suspended`）。
    他のアプリのクリックで閉じたとき（`.lostFocus`）・アプリを起動したとき（`.launched`）は戻さない
  - bundle id: 常用 `io.github.nyshk97.mycast` / dev `io.github.nyshk97.mycast.dev`
  - パネルのレベルは `.floating`（`LauncherController`）。「コピーしました」の通知は `.statusBar`（`Paster.swift` の `Toast`）
- memode の作り
  - `memode://show` は既にある（`DocumentService.openFromURL`。隠れていれば出す）
  - ペーストはメインメニューの `NSText.paste(_:)`（WKWebView → Monaco）。`PanelController.show()` は前面のアプリを変えずに `makeKeyAndOrderFront` する
  - 「前面は PolePole、キーは memode」はダブルタップで出したときと同じ並び。mycast が閉じて PolePole を前面に戻したあと、memode が key を取り直せば元に戻る
  - URL スキーム: 常用 `memode://` / dev `memode-dev://`。bundle id: `local.nyshk97.memode` / `local.nyshk97.memode.dev`

### 決めたこと

| 場面 | mycast | memode |
|---|---|---|
| memode が出ているときに ⌃L | 開く。memode を「戻り先」として覚える（貼り先・戻す先は今まで通り PolePole も覚えておく） | 隠れない。「mycast に貸している」状態になる |
| 履歴から選んで貼る（Enter） | 閉じる → 入力ソースを戻す → PolePole を 1 回前面にして待つ → ペーストボードに書く → `memode://paste` を前面にしない開き方で送る（⌘V は合成しない） | パネルを key にして、エディタにペーストする。貸している状態を抜ける |
| Esc / ⌃L 再押下 / ⌘Enter（コピーだけ） | 閉じる → PolePole を前面に戻す → `memode://focus` | パネルを key にする（ペーストはしない）。貸している状態を抜ける |
| mycast からアプリを起動 / 他のアプリをクリックして閉じた | 今まで通り（何もしない） | 前面になったのが mycast と PolePole（memode が key を持っていた間の前面。`show()` で控えるもの）以外なら隠れる。貸した時点の前面は通常 mycast になっているので使わない |
| PolePole をクリックして閉じた（Secure Event Input 中に閉じた場合も） | 今まで通り | mycast のウィンドウが画面から消えてから 2.5 秒以内に focus / paste が来なければ隠れる（mycast の前面化の待ち上限 1.05 秒より十分長くする） |
| mycast が開いたまま memode のパネルをクリックした | 今まで通り（`.lostFocus` で閉じて何も送らない） | パネルが key に戻った時点で貸している状態を抜ける |
| 絵文字（⌃⌘Space）から貼る | クリップボード履歴と同じ経路（`Paster` を通るので共通） | 同上 |

- 「memode が出ていたか」は mycast が開く**前**（`NSApp.activate` より前）に、画面のウィンドウ一覧（`CGWindowListCopyWindowInfo`。
  画面収録の許可は要らない。所有プロセスの pid・レイヤー・大きさだけ見る）で、memode のパネル（レイヤーが `.floating`、画面に出ている、一定以上の大きさ）があるかで決める。
  memode のメニューバーのアイテムも同じ pid のウィンドウ（レイヤー 25）として出ているので、レイヤーで外す。
  memode は外にキーが移ると（mycast 以外へは）隠れるので、出ていればキーを持っていたとみなせる
- 送り先は出ていた memode の bundle id で決める（`local.nyshk97.memode` → `memode://`、`.dev` → `memode-dev://`）。
  dev 版どうし・常用版どうしに限らない（出ている方に返す）。両方出ていたら、ウィンドウ一覧で手前にある方に返す
- `memode://paste` / `memode://focus` は `NSWorkspace.open(_:configuration:)` の `activates = false` で開く（memode を前面にしない）
- memode の「mycast へ貸した」の判定: キーを失った直後に、まず「mycast（常用・dev）のパネルが画面に出ている」かを見る（Secure Event Input 中でも効く）。
  パネルの見分け方は mycast 側の memode の見分け方と同じ（ウィンドウ一覧で、レイヤーが `.floating`・画面に出ている・一定以上の大きさ）。
  mycast のメニューバーのアイテムや「コピーしました」の通知（`.statusBar`）はレイヤーで外す。
  当たらなければ前面のアプリが mycast かを見る。`frontmostApplication` は非同期に更新されるので、どちらにも当たらないときはすぐ隠さず、
  `didActivateApplicationNotification` を短い間待ってから決める（判定の純関数に「まだ材料が揃っていない → 待つ」を入れる）
- ペーストは memode 自身が `NSText.paste(_:)` を first responder（WKWebView）に送る。ペーストボードの中身は読むだけで書かない。
  パネルを key にしたあと、エディタにフォーカスが戻ったのを確かめてから送る（`show()` は JS に focus を投げるだけで待たない）
- リリースは memode を先に出してから mycast を出す（mycast だけ新しいと `memode://paste` を古い memode が無視して、貼り付けが黙って消える）
- URL はブラウザのリンクからも叩ける。`paste` はペーストボードの中身をエディタに入れるだけで、ファイルや外には何も書かないので確認は出さない。
  パネルが隠れているときに `paste` / `focus` が来たら、出して key にするだけにする（ペーストはしない。勝手に中身を入れない）

## 実装計画

### Phase 1: memode 側 [AI🤖]

- [x] `HideRules` に貸し借りの判定を足す（純関数）: キーを失ったとき「隠す / 貸す / 隠さない（自分のウィンドウ）」、
  貸している間に別のアプリが前面になったとき・mycast のウィンドウが消えたとき「隠す / 待つ」。ユニットテストを書く
  （「前面が mycast のときに貸した → PolePole が前面になっても待つ」「控えた前面が mycast になる経路を通っても PolePole を許す」を含める）
- [x] `PanelController`: 貸している状態（貸した時刻・memode が key を持っていた間の前面のアプリ）を持つ。`NSWorkspace.didActivateApplicationNotification` を見て、
  決定表どおりに隠す。mycast のパネルが消えたことを知らせる通知は無いので、貸している間だけウィンドウ一覧を短い間隔で見る（抜けたら止める）。
  消えてからの 2.5 秒の待ちを入れる。`show()` で前面のアプリを控えるとき、自分と同じく mycast（常用・dev）でも上書きしない。パネルが key に戻ったら（`windowDidBecomeKey`）貸している状態を抜ける。
  `focus` / `paste` では key にする前に理由を付けて抜けておき、`windowDidBecomeKey` は貸している状態が残っているときだけ `key` で抜ける
- [x] `DocumentService.openFromURL` に `focus` と `paste` を足す（貸している / 出ている → key にする（paste ならペースト）、隠れている → 出すだけ）
- [x] ログ: `panel.lend`・`panel.lend_end reason=focus|paste|key|other_app|timeout` を出す
- [x] dev 版の `--selftest` に足す（URL は `NSWorkspace.open` の `activates = false` で自分宛てに開く。④ 2.5 秒で隠れる、も足した）:
  ① 貸してから `memode-dev://focus` が届くまでのあいだ一度も隠れず（`isVisible` が false にならず `panel.hide` も出ない）、そのあと key に戻る
  ② key でない状態から `memode-dev://paste` を受け、selftest が退避・復元するペーストボードの文字列がエディタに入る
  ③ 貸している状態で mycast 以外のアプリ（Finder 等）を前面にすると隠れる。貸している状態は「mycast のパネル / 前面アプリ」の判定を差し替えて作る
  （①② は Finder を mycast とみなす差し替え、③ はみなさない差し替え）
- [x] 判定の差し替え口だけ先に入れ、そのコードで ①② が FAIL することを確かめてから本体を実装する
- [x] CLAUDE.md の構成に「mycast との受け渡し」を一段落書き足す、VERIFY.md に手順を足す

### Phase 2: mycast 側 [AI🤖]

- [x] `Sources/Core/` に純関数を足す: ウィンドウ一覧（手前からの順・bundle id・レイヤー・大きさ。画面に出ているものだけを渡す）から「戻り先の memode」（URL スキーム）を決める。テストを書く
- [x] `LauncherController.show`: `NSApp.activate` の前に戻り先の memode を決めて覚える（表示中に再び呼ばれたときは上書きしない）
- [x] `Paster.paste`: 戻り先が memode なら、⌘V の代わりに `memode://paste` を送る（それ以外の順序はそのまま）。アクセシビリティの許可が無くても送れる。
  元のアプリの前面化が上限（1.0 秒）を過ぎても、戻り先が memode なら「コピーだけ」に落とさず `memode://paste` を送る
- [x] `close` の `.escape, .toggle, .copied` で、元のアプリを前面にしたあと `memode://focus` を送る（`.suspended`・`.lostFocus`・`.launched` では送らない）
- [x] ログ: `panel.shown` に `return_to=memode|memode-dev|-`、送ったときに `handoff.sent url=...`
- [x] mycast の CLAUDE.md の罠に「memode への受け渡し」を書き足す、VERIFY.md に手順を足す

### 動作確認 [人間👨‍💻]

- [ ] 常用版どうしで: memode で入力中に ⌃L → 履歴から選んで Enter → memode のカーソル位置に入る。memode は隠れない
- [ ] ⌃L → Esc → memode にそのまま打てる
- [ ] ⌃L → 他のアプリをクリック → memode も隠れる
- [ ] memode を出していないときの ⌃L → 貼り付けが今まで通り元のアプリに入る
- [ ] 日本語入力のまま ⌃L → 貼ったあと memode の入力ソースが日本語に戻っている

## ログ

### 試したこと・わかったこと
- 修正前（差し替え口だけ入れた状態）の selftest: `handoff_focus NG stayed=false hides=1 lent=false`・`handoff_paste NG ... pasted=false`・
  `handoff_other_app_hides NG lent=false`・`handoff_timeout_hides NG lentBefore=false`。実装後は 4 つとも OK、全体で `ok=96 ng=0`
- selftest の「元のアプリ」は前面のアプリでは取れない（前の項目のダイアログで memode 自身が前面になっている）。`PanelController.previousApp` を読む
- 実物どうし（mycast の dev のフック）: memode が隠れているとき `return_to=-`（メニューバーのアイテムを数えない）、出ているとき `return_to=memode-dev`。
  Esc → `handoff.sent url=memode-dev://focus` → memode に `url.open memode-dev://focus`・`panel.show`。貼り付けの Enter はフックで撃てない（人が試す）

### 方針変更
- selftest の mycast の代わりは Finder 固定でなく、動いているふつうのアプリから選ぶ（元のアプリが Finder のことがある）。3 つ目のアプリも同じく選ぶ
- key を失って前面のアプリが元のまま（または memode 自身）のときは 0.25 秒だけ待ってからもう一度決める（`ResignDecision.wait`）。
  前面が mycast・元のアプリ以外ならすぐ隠す。元のアプリ（nonactivating では後ろにいるアプリ）をクリックしたときだけ 0.25 秒遅れて隠れる
- mycast の Esc 等の `focus` は、元のアプリが前面になったのを待ってから送る（`Paster.whenActive`。先に送ると、あとから前面になった元のアプリに key を取られる）
- CHANGELOG はリリースのときに書く決まり（「コミットごとには書かない」）なので、今回は触らない
