review session: 5e9f4bdf-0ec9-4858-b557-bc6fe9381538

## 1回目

````text
## P0
- 実装計画 > Phase 1 > 5（selftest ①） — ①「`memode-dev://focus` で key に戻る」は、修正前のコードでも PASS してしまいます。今の `openFromURL` は知らない host を `url.ignored` として受け、隠れていれば `panel.show()` で key にします。修正前のコードでは Finder などを前面にした時点でパネルが隠れ（focusLost）、そのあと来た `focus` で出し直されて key になります。さらに修正前のコードには「貸している状態」を作る差し替え口が無いので、Phase 1 > 6 の「修正前で FAIL を確かめる」がこのままでは成り立ちません / そのまま進めると、テストが FAIL しないか、そもそもコンパイルが通らず、手順 6 をやり直すことになります / ① の判定を「キーを失ってから `focus` が届くまでのあいだ `isVisible` が一度も false にならず、`panel.hide` も出ていない。そのうえで key に戻る」に変えます。前面アプリの差し替え口は Phase 1 > 2 で入るので、手順 6 は「差し替え口だけ先に入れて FAIL を見る」と書き直します

## P1
- 決めたこと > 「memode が出ていたか」の判定 — 「レイヤーだけ見る」とあるだけで、どのレイヤーかが決まっていません。memode はメニューバーのアイテムを持っていて、そのウィンドウも memode の pid で画面上にあります（レイヤー 25）。ここを絞らないと、memode が隠れているときでも「出ている」と判定されます / 隠れているのに `memode://paste` が送られて、⌘V は合成されません。動作確認の「memode を出していないときの ⌃L → 元のアプリに入る」が壊れます / 判定を「`kCGWindowLayer == NSWindow.Level.floating`（3）、かつ onscreen、かつ bounds が一定以上」と明記します。Phase 2 > 1 のテストに「ステータスアイテムのウィンドウだけがある → 戻り先なし」を入れます
- 決めたこと > 「mycast へ貸した」の判定 — 「`windowDidResignKey` の次のループで `frontmostApplication` が mycast か」で判定しています。`frontmostApplication` は workspace の通知で非同期に更新されるので、次のループではまだ PolePole のままのことがあり得ます。そうなると今と同じく focusLost で隠れます / 機能の芯なのに、通るかどうかがタイミング任せになります。しかも「実装時に要確認」のまま後回しになっています / Secure Event Input 用に挙げている「一番手前のウィンドウが mycast のもの（CGWindowList）」を、補助ではなく最初に見る判定にします。どちらにも当たらないときは、すぐ隠さずに `didActivateApplicationNotification` を短時間（例 150ms）待ってから決める、と書きます。`HideRules` には「判定材料が揃っていない → 待つ」も入れます
- 決めたこと > 表「PolePole をクリックして閉じた」 — Secure Event Input 中は mycast を開いても前面アプリは PolePole のままです。この状態で PolePole をクリックしても前面アプリが変わらず、`didActivateApplicationNotification` が来ません。1.5 秒の待ちが始まらず、memode は key を持たないまま出っぱなしになり、貸している状態も抜けません / 決定表どおりに隠れない経路が残ります / 待ちの起点を「前面が PolePole になった」に加えて「貸した時点ですでに前面が PolePole だった場合は、mycast のウィンドウが画面から消えたとき（CGWindowList を短い間隔で見る、または貸した時点から数えるタイムアウト）」にします。Phase 1 > 1 の純関数とテストにこのケースを足します
- 決めたこと > 表 / Phase 1 > 2 — mycast が開いている間に memode 自身をクリックした場合の扱いがありません（memode は `.floating` で見えたままなので、自然にやる操作です）。memode が key に戻り、mycast は `.lostFocus` で閉じて何も送りません / 貸している状態が残り続け、あとで別のアプリに切り替えたときに `other_app` として誤った経路で隠れたり、ログが `lend_end` 無しになったりします / `windowDidBecomeKey` で貸している状態を抜ける（`lend_end reason=key`）を Phase 1 > 2・4 に足し、決定表に 1 行加えます
- Phase 1 > 2（1.5 秒の待ち） — mycast の `Paster` は「PolePole を 1 回前面にして待つ」ので、その待ち時間ぶん `memode://paste` が届くのが遅れます。1.5 秒がこの待ちの上限より長いことが確かめられていません（mycast のソースはこのレビューでは読めませんでした） / 待ちの上限が 1.5 秒近いと memode が先に隠れます。決めたとおり、隠れたあとの `paste` は「出すだけ」なので、貼ったつもりの内容が入りません / `Paster` の待ちの上限値を「前提・わかっていること」に書き、1.5 秒はそれより十分長い値にします（または「上限＋余裕」で決めます）
- Phase 1 > 3（paste） — `show()` は `focusEditor()` で JS に `focus` を投げるだけで、Monaco の textarea にフォーカスが戻ったかは待っていません。その直後に `NSText.paste(_:)` を送ると、フォーカスが戻る前に paste が処理されるおそれがあります / ペーストが落ちたり、別の場所に入ったりします。selftest は条件次第で通ってしまい、再現しにくい不具合になります / paste は `makeKeyAndOrderFront` のあと、`debugState` 相当で `focused == true` を確かめてから（または 1 ループ置いてから）送る、と書きます。selftest ② は「隠れていない・key ではない状態から paste を受ける」順序で行います
- Phase 2 / 動作確認 — 出す順番が決まっていません。mycast だけ新しくなり memode が古いままだと、⌃L で memode は今まで通り隠れます。一方 mycast は開く前に「memode が出ていた」と判定するので `memode://paste` を送り、⌘V は合成しません。古い memode はこれを `url.ignored` として受けて出すだけになり、何も貼られません / 片方だけ更新した期間に、貼り付けが黙って消えます / 「memode を先にリリースしてから mycast をリリースする」と plan に書きます。memode の Phase 1 に CHANGELOG の `[Unreleased]` 記入も足します

## P2
- 決めたこと > 「送り先は出ていた memode の bundle id で決める」 — 常用版と dev 版が両方出ているときにどちらへ返すかが書かれていません（CLAUDE.md にある通り、左 Shift のダブルタップで両方が出ることがあります） / 「CGWindowList で手前にある方」などのルールを 1 行足すと実装が迷いません
- 前提・わかっていること > memode の作り — memode がファイル選択やアラートを出していて、key がそちらにある状態で ⌃L を押した場合、パネルの `windowDidResignKey` は呼ばれず、貸す判定に入りません。`focus` でパネルが key になると、ダイアログが後ろに残ることがあります / まれなケースなので、「パネルに sheet が付いている・modal 中は `focus` / `paste` で key を奪わない」程度の扱いを決めておくと安全です
- 動作確認 [人間👨‍💻] — ⌘Enter（コピーだけ）、⌃L 再押下、絵文字（⌃⌘Space）、PolePole をクリックしてから 1.5 秒で隠れる、の確認項目がありません。決定表の行と 1 対 1 になるように足すと、漏れが分かりやすくなります
- 実装計画 > Phase 1 > 5（selftest ①②） — URL を `openFromURL` に直接渡すのか、`NSWorkspace.open(_:configuration:)`（`activates = false`）で自分宛てに開くのかが書かれていません。後者なら、Launch Services 経由の受け取りと「前面にしない」も一緒に確かめられます

## Q

````

**対応**: P0（selftest ① が修正前でも PASS する）→ ① を「貸してから focus まで一度も隠れず、そのあと key に戻る」に変え、手順 6 を「差し替え口だけ先に入れて ①② の FAIL を見る」に書き換え。P1 レイヤー → floating・大きさで絞り、メニューバー（レイヤー 25）を外すと明記（テストケースの追加は見送り。条件の明記で足りる）。P1 貸した判定のタイミング → 「一番手前のウィンドウ」を先に見る・揃わなければ activate 通知を短く待つ、に書き換え。P1 Secure Input で PolePole クリック → 待ちの起点を「mycast のウィンドウが消えてから」に変更。P1 memode 自身のクリック → 決定表に 1 行、`windowDidBecomeKey` で抜ける。P1 1.5 秒 → mycast の待ち上限 1.0+0.05 秒を前提に書き、2.5 秒に変更。P1 paste のフォーカス → フォーカスが戻ってから送ると明記、② を key でない状態から受ける順に。P1 リリース順 → 「memode を先に出す」を明記（CHANGELOG の追記ステップはリリース手順の範囲なので足さない）。P2 両方出ているとき → 手前の方と 1 行。P2 selftest の URL の開き方 → activates=false で自分宛てと明記。見送り: P2 sheet/modal 中の扱い（足す修正。まれなケース）、P2 動作確認の項目追加（足す修正。終了報告に回す）

## 2回目

````text
## P0
- 実装計画 > Phase 1 > 2 — 「貸している状態（貸した時刻・**そのときの前面のアプリ**）を持つ」と書かれていて、決定表の「前面になったのが mycast と PolePole（貸した時点の前面）以外なら隠れる」はこの値を PolePole として使っています。ところが通常の経路（Secure Event Input でないとき）では、「前面のアプリが mycast か」で貸す判定をするので、貸した時点の前面は mycast です。PolePole にはなりません / Esc・Enter のどちらでも、mycast は URL を送る前に PolePole を前面に戻します。その時点で memode は PolePole を「mycast でも貸した時点の前面でもないアプリ」とみなして、すぐ隠れます。どの値になるかは `frontmostApplication` の更新タイミング次第なので、たまにしか起きない不具合になります / 許すアプリは「貸した時点の前面」ではなく「memode が key を持っていた間の前面」にします。memode は key を持っている間は前面を変えないので、`show()` が覚えている `previousApp`、または `windowDidBecomeKey` の時点で控えた前面のアプリが使えます。そのことを Phase 1 > 2 と決定表に書き、`HideRules` のテストに「前面が mycast のときに貸した → PolePole が前面になっても待つ」を入れます

## P1
- 決めたこと > 「mycast へ貸した」の判定 — 「画面の一番手前のウィンドウが mycast のもの」をそのまま CGWindowList の先頭で見ると、メニューバーや Dock、コントロールセンターなど上のレイヤーのウィンドウが先に来ます。mycast もメニューバーにアイテムを持っているなら、そのウィンドウも mycast の pid で常に画面に出ています。前回 mycast 側の判定で直したのと同じ問題が、memode 側に残っています / 「一番手前」がほぼ当たらないか、逆に常に当たります（ステータスアイテムがある場合）。後者だと Phase 1 > 2 の「mycast のウィンドウが消えてから 2.5 秒」の起点も来ません / memode 側の判定も「mycast の pid で、レイヤーが `.floating` 以上かつメニューバーより下、画面に出ている、一定以上の大きさのウィンドウがある」に揃えます。「消えた」もこの条件で見る、と書きます
- 実装計画 > Phase 1 > 2 — 「mycast のウィンドウが消えたとき」を何で知るかが書かれていません。ほかのアプリのウィンドウが閉じたことを知らせる通知はありません / 実装する人が決めることになります。通知で取れると思って作り始めると、作り直しになります / 「貸している間は CGWindowList を短い間隔（例 0.2 秒）で見る」と書きます。これは貸している間だけ動き、抜けたら止めます
- 決定表 > 履歴から選んで貼る（Enter） — mycast の `Paster` は、前面化の待ちが 1.0 秒を超えると「コピーだけ」に落とします。この場合に戻り先が memode なら何を送るかが決まっていません。Phase 2 > 3 の「それ以外の順序はそのまま」に従うと、何も送りません / PolePole がもたついただけで memode が 2.5 秒後に隠れ、ペーストも落ちます。memode に貼るときは PolePole が前面になっている必要はありません / 「戻り先が memode なら、待ちが上限を過ぎても `memode://paste` を送る」と Phase 2 > 3 に 1 行足します
- 実装計画 > Phase 2 > 1 — 純関数の入力が「pid・bundle id・レイヤー・画面に出ているか」のままです。決めたことで使う「一定以上の大きさ」と「両方出ていたら手前の方」が入力に入っていません / この入力のままでは、決めた規則を純関数の中で書けません / 入力に bounds と、ウィンドウ一覧での順序（手前からの位置）を足します

## P2
- 実装計画 > Phase 1 > 5（selftest ①②③） — ①② の「貸している状態」を作るとき、Finder を前面にしてパネルの key を外す想定だと思います。その場合、Finder を mycast とみなすように判定を差し替えないと、③ の規則で隠れてしまいます。①② と ③ で差し替えの中身が違う（①② は Finder を mycast とみなす、③ はみなさない）ことを 1 行書いておくと、実装で迷いません

## Q

````

**対応**: P0（許すアプリが「貸した時点の前面」= 通常 mycast で、PolePole の前面化で隠れる）→ 「memode が key を持っていた間の前面（`show()` で控えるもの）」に変更。決定表・Phase 1 > 2 を書き換え、HideRules のテストにこのケースを含めると明記。P1 memode 側の「一番手前」判定 → mycast 側と同じ見分け方（`.floating`・画面に出ている・大きさ。メニューバーのアイテムと通知 `.statusBar` はレイヤーで外す）に揃えた。P1 消えたことの検知 → 通知が無いので貸している間だけウィンドウ一覧を短い間隔で見る、と 1 行。P1 前面化の待ちが上限超え → 戻り先が memode なら「コピーだけ」に落とさず paste を送る、と Phase 2 > 3 に。P1 純関数の入力 → 手前からの順・bounds を足した。P2 selftest の差し替えの違い → ①② と ③ で中身が違うと 1 行

## 3回目

````text
## P0

## P1
- 決定表 > mycast からアプリを起動 / 他のアプリをクリックして閉じた — 許すアプリを「`show()` で控えるもの（`previousApp`）」にしました。ところが `show()` は、前面が自分以外ならそのアプリで `previousApp` を上書きします。前面が mycast のまま `show()` が呼ばれる経路が 2 つあります。1 つ目は、mycast が開いたまま memode のパネルをクリックしたとき（`.lostFocus` で閉じたあとも前面は mycast に残る）です。2 つ目は、前面化が上限を過ぎてもそのまま `paste` を送る今回の変更で、PolePole が前面になる前に memode が key に戻るときです（`focus` / `paste` で `show()` を通る場合）。どちらも `previousApp` が mycast になります / 次に ⌃L したとき、許すアプリが「mycast と mycast」になり、mycast が PolePole を前面に戻した瞬間に memode が `other_app` で隠れます。一度こうなると、隠して出し直すまで続きます / `show()` で控えるとき、自分と同じように mycast（常用・dev）も上書きしない対象にする、と Phase 1 > 2 に 1 行足します。`HideRules` のテストに「控えた前面が mycast になる経路を通っても PolePole を許す」を入れます

## P2
- 実装計画 > Phase 1 > 2・4 — `focus` / `paste` を受けてパネルを key にすると、その中で `windowDidBecomeKey` が同期的に呼ばれます。このとき先に `lend_end reason=key` で貸している状態を抜けるので、`reason=focus|paste` のログが出ません / 動作確認のログで、mycast から返ってきたのかパネルのクリックで戻ったのかが見分けられません / `openFromURL` 側で、key にする前に抜ける理由を決めて状態を閉じてしまい、`windowDidBecomeKey` は貸している状態が残っているときだけ `key` で抜ける、という順番を書いておきます
- 決めたこと > 「mycast へ貸した」の判定 — mycast のパネルを「レイヤーが `.floating`」で見分ける前提です。今回も mycast のソースは読めなかったので、パネルのウィンドウレベルが本当に `.floating` かは確かめられていません / もし違うレベルだと、最初の判定がいつも外れます。Secure Event Input 中は前面アプリでも判定できないので、隠れてしまいます / まだ確かめていなければ、mycast の `LauncherController` でパネルの `level` を確認し、値を「前提・わかっていること」に書きます

## Q

````

**対応**: 収束（P0 なし）。採用した P1/P2: P1 `show()` が前面を控えるとき mycast でも上書きしない、と Phase 1 > 2 に 1 句、HideRules のテストケースに 1 項目。P2 ログの理由 → focus / paste は key にする前に理由を付けて抜け、`windowDidBecomeKey` は残っているときだけ `key` で抜ける順と明記。P2 mycast のパネルのレベル → `LauncherController` で `.floating`、通知は `.statusBar` と確認し前提に追記
