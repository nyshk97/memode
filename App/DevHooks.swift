#if DEBUG
import AppKit

/// dev 版だけの起動引数。実機能と同じ経路を通す（検証専用の裏口は作らない）
///   --show                 起動したらポップアップを出す
///   --panel-style <style>  パネルの方式を一時的に切り替える（PanelStyle.current）
///   --selftest             キー操作を合成して、Phase 2 の項目を確かめてログに書く
///   --selftest-quit        自走の検証が終わったら終了する
///   --selftest-restore     前回の --selftest が残したセッションが戻ったかを確かめる（VERIFY.md の手順）
///   --data-dir <path>      データの置き場所を差し替える（自走の検証では必須）
///   --index-home <path>    Cmd+P で探すホームを差し替える（自走の検証では必須）
///   --snapshot <png>       表示が済んだらエディタ部分を PNG に保存する
///   --demo                 タブを何枚か開いて左右に分割した状態で出す（見た目の確認用）
enum DevHooks {
    static func run(app: AppDelegate) {
        let args = CommandLine.arguments
        let selftest = args.contains("--selftest") || args.contains("--selftest-restore")
        if selftest && (!args.contains("--data-dir") || !args.contains("--index-home")) {
            // 自走の検証はタブを作ったり閉じたりするので、手元の dev 版のメモ（~/Library/Application Support/Memode-dev）で回さない。
            // Cmd+P の一覧も本物のホームを走査しない（時間がかかり、許可のダイアログも出る）
            Log.write("selftest.refused", "--data-dir と --index-home に使い捨てのディレクトリを付けて起動する")
            NSApp.terminate(nil)
            return
        }
        if args.contains("--selftest") {
            Task { @MainActor in
                await SelfTest(app: app).run()
                if args.contains("--selftest-quit") { NSApp.terminate(nil) }
            }
        } else if args.contains("--selftest-restore") {
            Task { @MainActor in
                await SelfTest(app: app).runRestore()
                if args.contains("--selftest-quit") { NSApp.terminate(nil) }
            }
        } else if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            // 表示が済んだらエディタ部分を PNG に保存する（UI の確認用）
            let path = args[i + 1]
            let panel = app.panelController!
            panel.bridge.whenReady {
                panel.show()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    panel.webView.takeSnapshot(with: nil) { image, error in
                        guard let image, let tiff = image.tiffRepresentation,
                              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
                            Log.write("snapshot.failed", "\(String(describing: error))")
                            return
                        }
                        do {
                            try png.write(to: URL(fileURLWithPath: path))
                            Log.write("snapshot.saved", path)
                        } catch {
                            Log.write("snapshot.failed", "\(error)")
                        }
                    }
                }
            }
        } else if args.contains("--demo") {
            // 見た目の確認用に、タブを何枚か開いて左右に分割した状態を作る（メニューと同じ経路で）
            let panel = app.panelController!
            panel.bridge.whenReady {
                panel.show()
                let send = panel.bridge.send
                send(["type": "setContent", "value": "買い物メモ\n- 牛乳\n- パン\n\n明日やること\n- 歯医者の予約"])
                send(["type": "command", "name": "new_tab", "index": 0])
                send(["type": "setContent", "value": "def greet(name: str) -> str:\n    # あいさつを返す\n    return f\"こんにちは、{name}\"\n\nprint(greet(\"memode\"))\n", "language": "python"])
                send(["type": "command", "name": "new_tab", "index": 0])
                send(["type": "setContent", "value": "{\n  \"name\": \"memode\",\n  \"tabs\": 3\n}\n", "language": "json"])
                send(["type": "command", "name": "select_tab", "index": 2])
                send(["type": "command", "name": "toggle_split", "index": 0])
                send(["type": "command", "name": "select_tab", "index": 1])
            }
        } else if args.contains("--show") {
            app.panelController.show()
        }
    }
}

/// Phase 2 の自走の検証。キーは NSEvent を作って NSApp.sendEvent に流す
/// （アクセシビリティの許可が要らず、メニューへの経路も本物と同じになる）。
/// 結果は `selftest.<名前> OK|NG <詳細>` の行でログに出す
@MainActor
final class SelfTest {
    private let app: AppDelegate
    private var ok = 0
    private var ng = 0
    private var panel: PanelController { app.panelController }

    init(app: AppDelegate) {
        self.app = app
    }

    func run() async {
        Log.write("selftest.start", "style=\(panel.style.rawValue)")
        await withCheckedContinuation { c in panel.bridge.whenReady { c.resume() } }
        let activeBefore = NSApp.isActive
        let frontBefore = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
        panel.show()
        await sleep(0.8)
        let frontAfter = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
        check("panel_is_key", panel.panel.isKeyWindow,
              "isKeyWindow=\(panel.panel.isKeyWindow) appActive=\(activeBefore)->\(NSApp.isActive) frontmost=\(frontBefore)->\(frontAfter)")

        // 0. シンタックスハイライトが効く（worker も読める）
        panel.bridge.send(["type": "setContent", "value": "const answer = 42; // コメント\nfunction f() { return \"x\" }", "language": "javascript"])
        await sleep(1.0)
        let hl = await panel.bridge.debugState()
        check("syntax_highlight", (hl?["tokenClassCount"] as? Int ?? 0) >= 3, "tokenClassCount=\(hl?["tokenClassCount"] ?? "nil")")
        check("worker_loaded", (hl?["workerLoaded"] as? Bool) == true, "workerLoaded=\(hl?["workerLoaded"] ?? "nil")")

        // 1. Cmd+Opt+↓ でカーソルが増える／Esc で戻る
        panel.bridge.send(["type": "setContent", "value": "aaa\nbbb\nccc"])
        await sleep(0.3)
        await key(Key.down, [.command, .option])
        var state = await panel.bridge.debugState()
        check("add_cursor_below", (state?["cursorCount"] as? Int) == 2, "cursorCount=\(state?["cursorCount"] ?? "nil")")
        await key(Key.escape)
        state = await panel.bridge.debugState()
        check("escape_single_cursor", (state?["cursorCount"] as? Int) == 1, "cursorCount=\(state?["cursorCount"] ?? "nil")")

        // 2. Opt+↓ で行が動く（カーソルは 1 行目）
        await key(Key.down, [.option])
        state = await panel.bridge.debugState()
        check("move_line_down", (state?["value"] as? String) == "bbb\naaa\nccc", "value=\(String(describing: state?["value"]))")

        // 3. アプリのショートカットがメインメニューに届く
        let shortcuts: [(String, UInt16, String, NSEvent.ModifierFlags, String)] = [
            ("cmd_n", Key.n, "n", [.command], "new_tab"),
            ("cmd_p", Key.p, "p", [.command], "quick_open"),
            ("cmd_s", Key.s, "s", [.command], "save"),
            ("cmd_shift_s", Key.s, "s", [.command, .shift], "save_as"),
            ("cmd_w", Key.w, "w", [.command], "close_tab"),
            ("cmd_1", Key.one, "1", [.command], "select_tab:1"),
            ("ctrl_tab", Key.tab, "\t", [.control], "next_tab"),
            ("cmd_backslash", Key.backslash, "\\", [.command], "toggle_split"),
        ]
        let menuFiles = AppInfo.dataDirectory.appendingPathComponent("files")
        try? FileManager.default.createDirectory(at: menuFiles, withIntermediateDirectories: true)
        for (name, code, chars, mods, expected) in shortcuts {
            // 保存はダイアログを飛ばして使い捨てのパスに書く
            if expected == "save" || expected == "save_as" {
                app.documents.savePathOverride = menuFiles.appendingPathComponent("menu-\(name).txt").path
            }
            let before = app.menuActionLog.count
            await key(code, mods, chars: chars)
            let got = app.menuActionLog.count > before ? app.menuActionLog.last! : "(none)"
            check("menu_\(name)", got == expected, "got=\(got)")
        }

        // 4. Cmd+A・C・X・V がエディタで効く（ユーザーのクリップボードは最後に戻す）
        let saved = savePasteboard()
        let text = (await panel.bridge.debugState())?["value"] as? String ?? ""
        await key(Key.a, [.command], chars: "a")
        await key(Key.c, [.command], chars: "c")
        let copied = NSPasteboard.general.string(forType: .string)
        // クリップボードの中身はログに出さない（失敗したときにユーザーのクリップボードが残るため）
        check("cmd_a_c", copied == text, "clipboardMatches=\(copied == text) length=\(copied?.count ?? -1)")
        await key(Key.x, [.command], chars: "x")
        let afterCut = (await panel.bridge.debugState())?["value"] as? String
        check("cmd_x", afterCut == "", "value=\(String(describing: afterCut))")
        await key(Key.v, [.command], chars: "v")
        let afterPaste = (await panel.bridge.debugState())?["value"] as? String
        check("cmd_v", afterPaste == text, "value=\(String(describing: afterPaste))")
        restorePasteboard(saved)

        // 5. Cmd+O のファイル選択画面がポップアップより前に出る
        await key(Key.o, [.command], chars: "o")
        await sleep(1.0)
        let order = onscreenWindowOrder()
        let panelIndex = order.firstIndex { $0.number == panel.panel.windowNumber }
        let sheetNumber = panel.panel.attachedSheet?.windowNumber
        let dialogIndex = order.firstIndex { $0.number == sheetNumber }
            ?? order.firstIndex { $0.owner.localizedCaseInsensitiveContains("open") && $0.owner.localizedCaseInsensitiveContains("save") }
        let detail = "panelIndex=\(String(describing: panelIndex)) dialogIndex=\(String(describing: dialogIndex)) sheet=\(panel.panel.attachedSheet != nil) top=\(order.prefix(4).map { "\($0.owner)#\($0.layer)" })"
        if let d = dialogIndex, let p = panelIndex {
            check("open_panel_in_front", d < p, detail)
        } else {
            check("open_panel_in_front", false, detail)
        }
        check("panel_stays_with_dialog", panel.isVisible, "visible=\(panel.isVisible)")
        app.currentOpenPanel?.cancel(nil)
        await sleep(0.8)
        check("panel_key_after_dialog", panel.panel.isKeyWindow, "isKeyWindow=\(panel.panel.isKeyWindow)")

        // 6. 隠して出し直すと、フォーカスとカーソル位置が戻る
        panel.bridge.send(["type": "setContent", "value": "one\ntwo\nthree"])
        await key(Key.down)
        await key(Key.right)
        let before = (await panel.bridge.debugState())?["cursors"] as? [[String: Int]]
        panel.hide(reason: .toggle)
        await sleep(0.5)
        panel.show()
        await sleep(0.8)
        let after = await panel.bridge.debugState()
        let afterCursors = after?["cursors"] as? [[String: Int]]
        check("refocus_after_show", (after?["focused"] as? Bool) == true && before != nil && afterCursors == before,
              "focused=\(String(describing: after?["focused"])) before=\(String(describing: before)) after=\(String(describing: afterCursors))")

        // 7. タブと左右分割（Phase 4）
        await tabsAndSplit()

        // 8. Cmd+O で開く（Phase 6）
        await openFiles()

        // 8b. Cmd+P・memode:// で開く（Phase 6）
        await quickOpenAndURL()

        // 9. 保存・外での書き換え・閉じる前の確認（Phase 5）
        await saveAndFiles()

        // 9b. エディタ以外のページへは移動しない（ドロップされたファイル・リンク等）
        _ = try? await panel.webView.evaluateJavaScript("location.href = 'about:blank'; true")
        await sleep(0.6)
        let stillAlive = (await panel.bridge.debugState())?["workspace"] != nil
        check("navigation_blocked", stillAlive && panel.webView.url?.scheme == EditorSchemeHandler.scheme,
              "url=\(panel.webView.url?.absoluteString ?? "nil") alive=\(stillAlive)")

        // 9c. ステータスバーの版の表示。dev 版は「dev」で押せない。新しい版があると「vX.Y.Z に更新」になり、押すとポップアップを隠す
        let devVersion = (await panel.bridge.debugState())?["statusVersion"] as? [String: Any]
        check("status_version_dev", devVersion?["text"] as? String == "dev" && devVersion?["clickable"] as? Bool == false,
              "statusVersion=\(String(describing: devVersion))")
        panel.bridge.send(["type": "appInfo", "version": "0.1.1", "dev": false, "update": "9.9.9"])
        await sleep(0.3)
        let updateVersion = (await panel.bridge.debugState())?["statusVersion"] as? [String: Any]
        check("status_version_update", updateVersion?["text"] as? String == "v9.9.9 に更新" && updateVersion?["clickable"] as? Bool == true,
              "statusVersion=\(String(describing: updateVersion))")
        _ = try? await panel.webView.evaluateJavaScript("document.getElementById('status-version').click(); true")
        await sleep(0.5)
        check("status_version_click_hides", !panel.isVisible && app.menuActionLog.last == "check_for_updates",
              "visible=\(panel.isVisible) last=\(app.menuActionLog.last ?? "nil")")
        panel.bridge.send(["type": "appInfo", "version": AppInfo.version, "dev": true, "update": NSNull()])
        panel.show()
        await sleep(0.8)

        // 10. 左 Shift のダブルタップで出し入れする（監視から届いたイベントと同じ入口に流す）
        panel.hide(reason: .toggle)
        await sleep(0.3)
        let monitor = app.shiftTapMonitor!
        func tap(_ t: TimeInterval, length: TimeInterval = 0.08) {
            monitor.feed(kind: .flagsChanged, keyCode: 56, modifierFlags: 0x20002, timestamp: t)
            monitor.feed(kind: .flagsChanged, keyCode: 56, modifierFlags: 0x100, timestamp: t + length)
        }
        // シナリオの間で判定の途中の状態を持ち越さない（未来の時刻を付けて流しているため）
        func reset() { monitor.feed(kind: .keyDown, keyCode: 0, modifierFlags: 0, timestamp: 0) }
        var t = ProcessInfo.processInfo.systemUptime
        tap(t); tap(t + 0.2)
        await sleep(0.8)
        check("double_tap_shows", panel.isVisible && panel.panel.isKeyWindow, "visible=\(panel.isVisible) key=\(panel.panel.isKeyWindow)")
        reset()
        t = ProcessInfo.processInfo.systemUptime
        tap(t); tap(t + 0.2)
        await sleep(0.5)
        check("double_tap_hides", !panel.isVisible, "visible=\(panel.isVisible)")
        reset()
        // 間に他のキー（Shift+A で大文字を打った等）が入ったら出さない
        t = ProcessInfo.processInfo.systemUptime
        tap(t)
        monitor.feed(kind: .keyDown, keyCode: 0, modifierFlags: 0x20002, timestamp: t + 0.12)
        tap(t + 0.2)
        await sleep(0.5)
        check("double_tap_cancelled_by_other_key", !panel.isVisible, "visible=\(panel.isVisible)")
        reset()
        // 間隔が空きすぎたら出さない
        t = ProcessInfo.processInfo.systemUptime
        tap(t); tap(t + 0.8)
        await sleep(0.5)
        check("double_tap_too_slow", !panel.isVisible, "visible=\(panel.isVisible)")
        reset()
        // 右 Shift（keyCode 60）では出さない
        t = ProcessInfo.processInfo.systemUptime
        for d in [0.0, 0.2] {
            monitor.feed(kind: .flagsChanged, keyCode: 60, modifierFlags: 0x20004, timestamp: t + d)
            monitor.feed(kind: .flagsChanged, keyCode: 60, modifierFlags: 0x100, timestamp: t + d + 0.08)
        }
        await sleep(0.5)
        check("right_shift_ignored", !panel.isVisible, "visible=\(panel.isVisible)")

        panel.hide(reason: .toggle)
        Log.write("selftest.done", "style=\(panel.style.rawValue) ok=\(ok) ng=\(ng)")
    }

    // MARK: - Phase 4

    private func workspace() async -> (groups: [[String: Any]], activeGroup: Int, docCount: Int, value: String) {
        let state = await panel.bridge.debugState()
        let ws = state?["workspace"] as? [String: Any] ?? [:]
        return (ws["groups"] as? [[String: Any]] ?? [], ws["activeGroup"] as? Int ?? -1,
                ws["docCount"] as? Int ?? -1, state?["value"] as? String ?? "")
    }

    private func tabs(_ group: [String: Any]) -> [[String: Any]] { group["tabs"] as? [[String: Any]] ?? [] }
    private func activeIndex(_ group: [String: Any]) -> Int { group["active"] as? Int ?? -1 }

    private func tabsAndSplit() async {
        panel.show()
        await sleep(0.5)
        // 前の項目で分割していたら戻し、タブを 1 枚にする
        if (await workspace()).groups.count > 1 { await key(Key.backslash, [.command], chars: "\\") }
        for _ in 0..<10 {
            guard tabs((await workspace()).groups.first ?? [:]).count > 1 else { break }
            await key(Key.w, [.command], chars: "w")
        }

        panel.bridge.send(["type": "setContent", "value": "買い物メモ\n牛乳"])
        await sleep(0.3)
        var ws = await workspace()
        let firstTitle = tabs(ws.groups[0]).first?["title"] as? String
        check("tab_title_from_first_line", firstTitle == "買い物メモ", "title=\(String(describing: firstTitle))")

        await key(Key.n, [.command], chars: "n")
        ws = await workspace()
        let newTitle = tabs(ws.groups[0]).last?["title"] as? String ?? ""
        check("cmd_n_new_tab", tabs(ws.groups[0]).count == 2 && activeIndex(ws.groups[0]) == 1 && ws.value == "" && newTitle.hasPrefix("無題-"),
              "tabs=\(tabs(ws.groups[0]).count) active=\(activeIndex(ws.groups[0])) title=\(newTitle)")
        panel.bridge.send(["type": "setContent", "value": "second"])
        await sleep(0.3)

        await key(Key.one, [.command], chars: "1")
        ws = await workspace()
        check("cmd_1_selects_first", activeIndex(ws.groups[0]) == 0 && ws.value == "買い物メモ\n牛乳", "active=\(activeIndex(ws.groups[0]))")
        await key(Key.tab, [.control], chars: "\t")
        ws = await workspace()
        check("ctrl_tab_next", activeIndex(ws.groups[0]) == 1 && ws.value == "second", "active=\(activeIndex(ws.groups[0]))")

        // 分割すると、右に同じ文書が開く（model を共有するので文書は増えない）
        let docsBefore = ws.docCount
        await key(Key.backslash, [.command], chars: "\\")
        ws = await workspace()
        let leftId = ws.groups.first.flatMap { tabs($0)[safe: activeIndex($0)]?["id"] as? Int }
        let rightId = ws.groups.count > 1 ? tabs(ws.groups[1]).first?["id"] as? Int : nil
        check("split_opens_same_doc", ws.groups.count == 2 && ws.activeGroup == 1 && leftId == rightId && ws.docCount == docsBefore,
              "groups=\(ws.groups.count) activeGroup=\(ws.activeGroup) left=\(String(describing: leftId)) right=\(String(describing: rightId)) docs=\(ws.docCount)")
        panel.bridge.send(["type": "setContent", "value": "shared edit"])
        await sleep(0.3)

        // 右で新しいタブを作ってから分割を戻すと、右にしか無いタブは左へ移る
        await key(Key.n, [.command], chars: "n")
        panel.bridge.send(["type": "setContent", "value": "right only"])
        await sleep(0.3)
        await key(Key.backslash, [.command], chars: "\\")
        ws = await workspace()
        let titles = tabs(ws.groups[0]).compactMap { $0["title"] as? String }
        check("unsplit_keeps_tabs", ws.groups.count == 1 && titles == ["買い物メモ", "shared edit", "right only"], "groups=\(ws.groups.count) titles=\(titles)")

        // 言語を選ぶ（絞り込みに打って Enter）
        await key(Key.one, [.command], chars: "1")
        panel.bridge.send(["type": "command", "name": "choose_language"])
        await sleep(0.4)
        for (code, ch) in [(Key.p, "p"), (Key.y, "y"), (Key.t, "t"), (Key.h, "h"), (Key.o, "o"), (Key.n, "n")] {
            await key(code, chars: ch)
        }
        await key(Key.enter, chars: "\r")
        let lang = tabs((await workspace()).groups[0]).first?["language"] as? String
        check("choose_language", lang == "python", "language=\(String(describing: lang))")

        // 全部閉じると、空のメモが 1 枚残る（使い捨てメモは確認なしで消える）
        for _ in 0..<3 { await key(Key.w, [.command], chars: "w") }
        ws = await workspace()
        check("close_all_leaves_empty", tabs(ws.groups[0]).count == 1 && ws.value == "" && ws.docCount == 1,
              "tabs=\(tabs(ws.groups[0]).count) docs=\(ws.docCount) value=\(ws.value.count)")
    }

    // MARK: - Phase 5

    private var docs: DocumentService { app.documents }
    private var dataDir: URL { AppInfo.dataDirectory }

    private func activeTab() async -> [String: Any] {
        let ws = await workspace()
        guard ws.activeGroup >= 0, ws.activeGroup < ws.groups.count else { return [:] }
        let g = ws.groups[ws.activeGroup]
        return tabs(g)[safe: activeIndex(g)] ?? [:]
    }

    private func fileText(_ path: String) -> String? {
        (try? Data(contentsOf: URL(fileURLWithPath: path))).flatMap { String(data: $0, encoding: .utf8) }
    }

    private func hideAndShow() async {
        panel.hide(reason: .toggle)
        await sleep(0.4)
        panel.show()
        await sleep(0.8)
    }

    private func clickAlert(_ index: Int, _ name: String) async {
        guard let alert = docs.currentAlert else {
            check(name, false, "確認が出ていない")
            return
        }
        alert.buttons[index].performClick(nil)
        await sleep(0.5)
    }

    private func openFiles() async {
        panel.show()
        await sleep(0.4)
        let dir = dataDir.appendingPathComponent("files")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let py = dir.appendingPathComponent("open-me.py").path
        try? "print('hi')\n".write(toFile: py, atomically: true, encoding: .utf8)

        // 空のメモを見ているときに開くと、そのタブを置き換える
        await key(Key.n, [.command], chars: "n")
        let before = tabs((await workspace()).groups[0]).count
        docs.openPathOverride = py
        await key(Key.o, [.command], chars: "o")
        await sleep(0.4)
        var ws = await workspace()
        var tab = await activeTab()
        check("cmd_o_opens_file", tab["title"] as? String == "open-me.py" && tab["language"] as? String == "python"
              && ws.value == "print('hi')\n" && tabs(ws.groups[0]).count == before && tab["dirty"] as? Bool == false,
              "tab=\(tab) tabs=\(before)->\(tabs(ws.groups[0]).count)")

        // 同じファイルをもう一度開くと、タブを増やさずに切り替える
        await key(Key.n, [.command], chars: "n")
        panel.bridge.send(["type": "setContent", "value": "別のメモ"])
        await sleep(0.3)
        let count = tabs((await workspace()).groups[0]).count
        docs.openPathOverride = py
        await key(Key.o, [.command], chars: "o")
        await sleep(0.4)
        ws = await workspace()
        tab = await activeTab()
        check("cmd_o_same_file_switches", tab["title"] as? String == "open-me.py" && tabs(ws.groups[0]).count == count,
              "tab=\(tab["title"] ?? "nil") tabs=\(count)->\(tabs(ws.groups[0]).count)")

        // UTF-8 でないファイルは開かずに理由を出す
        let sjis = dir.appendingPathComponent("sjis.txt").path
        try? Data([0x82, 0xA0]).write(to: URL(fileURLWithPath: sjis))
        docs.openPathOverride = sjis
        await key(Key.o, [.command], chars: "o")
        await sleep(0.4)
        check("cmd_o_rejects_non_utf8", docs.currentAlert?.informativeText.contains("UTF-8") == true,
              "alert=\(docs.currentAlert?.informativeText ?? "nil")")
        await clickAlert(0, "dismiss_error")
        let recent = docs.recentFiles.first
        check("recent_files", recent == py, "recent=\(String(describing: recent))")
    }

    private func typeText(_ text: String) async {
        let codes: [Character: UInt16] = ["a": 0, "b": 11, "d": 2, "m": 46, ".": 47, "s": 1, "w": 13, "i": 34, "f": 3, "t": 17]
        for ch in text {
            guard let code = codes[ch] else { continue }
            await key(code, chars: String(ch))
        }
    }

    /// memode コマンドと同じ形の URL（パスは encodeURIComponent 相当で包む）
    private func memodeURL(_ path: String) -> URL {
        let enc = path.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? path
        return URL(string: "\(AppInfo.urlScheme)://open?path=\(enc)")!
    }

    private func quickOpenAndURL() async {
        panel.show()
        await sleep(0.4)
        // Cmd+P はホームの下を全部探す。除く場所（OrbStack・Library・隠しディレクトリ・node_modules・.gitignore）は出さない。
        // Library/CloudStorage（Dropbox 等）は入る。ホームの外は登録したフォルダだけ
        let home = DocumentService.indexHome
        func make(_ base: URL, _ rels: [String]) {
            for rel in rels {
                let url = base.appendingPathComponent(rel)
                try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? "content of \(rel)\n".write(to: url, atomically: true, encoding: .utf8)
            }
        }
        make(home, ["proj/a.swift", "proj/sub/b.md", "proj/node_modules/pkg/x.js", "OrbStack/docker/big.txt", ".ssh/id_secret",
                    ".zshrc-like", "Library/Preferences/pref.plist", "Library/CloudStorage/Dropbox/notes.md",
                    "repo/main.go", "repo/debug.log", "repo/.gitignore", ".config/tool.toml",
                    "Library/CloudStorage/Dropbox/dotfiles/.claude/ref.md", "Library/CloudStorage/Dropbox/dotfiles/.ssh/id_rsa"])
        try? "*.log\n".write(to: home.appendingPathComponent("repo/.gitignore"), atomically: true, encoding: .utf8)
        let git = Process()
        git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        git.arguments = ["-C", home.appendingPathComponent("repo").path, "init", "-q"]
        try? git.run()
        git.waitUntilExit()
        let outside = dataDir.appendingPathComponent("outside").resolvingSymlinksInPath()
        make(outside, ["far.txt"])
        docs.registerFolder(outside.path)
        docs.refreshIndex(force: true)
        await sleep(0.8)
        await key(Key.p, [.command], chars: "p")
        var qp: [String: Any]?
        let started = Date()
        for _ in 0..<40 {
            qp = (await panel.bridge.debugState())?["quickPick"] as? [String: Any]
            if qp?["open"] as? Bool == true { break }
            await sleep(0.1)
        }
        Log.write("selftest.cmd_p_wait", "ms=\(Int(Date().timeIntervalSince(started) * 1000))")
        let all = Set((qp?["allPaths"] as? [String] ?? []).filter { $0.hasPrefix(home.path + "/") }.map { String($0.dropFirst(home.path.count)) })
        let want: Set = ["/proj/a.swift", "/proj/sub/b.md", "/.zshrc-like", "/Library/CloudStorage/Dropbox/notes.md", "/repo/main.go", "/repo/.gitignore",
                         "/Library/CloudStorage/Dropbox/dotfiles/.claude/ref.md"]
        let notWant: Set = ["/proj/node_modules/pkg/x.js", "/OrbStack/docker/big.txt", "/.ssh/id_secret", "/Library/Preferences/pref.plist", "/repo/debug.log",
                            "/.config/tool.toml", "/Library/CloudStorage/Dropbox/dotfiles/.ssh/id_rsa"]
        let farListed = (qp?["allPaths"] as? [String] ?? []).contains(outside.appendingPathComponent("far.txt").path)
        check("cmd_p_home_index", qp?["open"] as? Bool == true && want.isSubset(of: all) && all.isDisjoint(with: notWant) && farListed,
              "missing=\(want.subtracting(all)) unwanted=\(all.intersection(notWant)) outside=\(farListed) home=\(home.path) paths=\((qp?["allPaths"] as? [String] ?? []).prefix(12))")
        await typeText("bmd")
        qp = (await panel.bridge.debugState())?["quickPick"] as? [String: Any]
        let top = (qp?["labels"] as? [String])?.first
        check("cmd_p_fuzzy", top == "b.md", "top=\(String(describing: top))")
        await key(Key.enter, chars: "\r")
        await sleep(0.4)
        var tab = await activeTab()
        var value = (await workspace()).value
        check("cmd_p_opens", tab["title"] as? String == "b.md" && value == "content of proj/sub/b.md\n", "tab=\(tab["title"] ?? "nil") value=\(value)")

        // memode:// で開く: 空白・日本語・# & を含むパス
        let odd = dataDir.appendingPathComponent("files/メモ #1 & test.txt").path
        try? "変な名前\n".write(toFile: odd, atomically: true, encoding: .utf8)
        app.application(NSApp, open: [memodeURL(odd)])
        await sleep(0.5)
        tab = await activeTab()
        value = (await workspace()).value
        check("url_open_odd_name", tab["path"] as? String == odd && value == "変な名前\n", "tab=\(tab["title"] ?? "nil")")

        // 無いパスは新しいファイルとして開き、保存したときに作る
        let newFile = dataDir.appendingPathComponent("files/sub dir/../new.md").path
        let normalized = (newFile as NSString).standardizingPath
        try? FileManager.default.removeItem(atPath: normalized)
        app.application(NSApp, open: [memodeURL(newFile)])
        await sleep(0.5)
        tab = await activeTab()
        check("url_open_new_file", tab["path"] as? String == normalized && tab["language"] as? String == "markdown"
              && !FileManager.default.fileExists(atPath: normalized), "tab=\(tab)")
        panel.bridge.send(["type": "setContent", "value": "# 新しいファイル\n"])
        await sleep(0.3)
        await key(Key.s, [.command], chars: "s")
        await sleep(0.5)
        check("new_file_created_on_save", fileText(normalized) == "# 新しいファイル\n", "file=\(String(describing: fileText(normalized)))")

        // ディレクトリは確認してから登録する
        let dir2 = dataDir.appendingPathComponent("proj2")
        try? FileManager.default.createDirectory(at: dir2, withIntermediateDirectories: true)
        try? "y\n".write(to: dir2.appendingPathComponent("y.txt"), atomically: true, encoding: .utf8)
        app.application(NSApp, open: [memodeURL(dir2.path)])
        await sleep(0.4)
        check("url_dir_asks", docs.currentAlert != nil && !docs.folders.contains(dir2.path), "alert=\(docs.currentAlert?.messageText ?? "nil")")
        await clickAlert(0, "url_dir_register")
        await sleep(0.6)
        qp = (await panel.bridge.debugState())?["quickPick"] as? [String: Any]
        check("url_dir_registered", docs.folders.contains(dir2.resolvingSymlinksInPath().path) && qp?["open"] as? Bool == true, "folders=\(docs.folders.count) quickPick=\(String(describing: qp?["open"]))")
        await key(Key.escape)

        // 相対パスなど、形のおかしい URL は無視する
        let tabsBefore = (await workspace()).groups.map { tabs($0).count }
        app.application(NSApp, open: [URL(string: "\(AppInfo.urlScheme)://open?path=relative/path.txt")!])
        await sleep(0.4)
        let tabsAfter = (await workspace()).groups.map { tabs($0).count }
        check("url_relative_ignored", tabsAfter == tabsBefore, "tabs=\(tabsBefore)->\(tabsAfter)")
    }

    private func saveAndFiles() async {
        panel.show()
        await sleep(0.4)
        let saved = dataDir.appendingPathComponent("files/saved.md").path
        try? FileManager.default.createDirectory(atPath: (saved as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(atPath: saved)

        // メモを Cmd+S で保存する（保存ダイアログだけ飛ばす）
        await key(Key.n, [.command], chars: "n")
        panel.bridge.send(["type": "setContent", "value": "保存テスト\nline2"])
        await sleep(0.3)
        docs.savePathOverride = saved
        await key(Key.s, [.command], chars: "s")
        await sleep(0.5)
        var tab = await activeTab()
        check("save_untitled", fileText(saved) == "保存テスト\nline2" && tab["path"] as? String == saved
              && tab["title"] as? String == "saved.md" && tab["language"] as? String == "markdown" && tab["dirty"] as? Bool == false,
              "file=\(String(describing: fileText(saved))) tab=\(tab)")

        // 書き足すと未保存になり、Cmd+S で上書きする
        panel.bridge.send(["type": "setContent", "value": "保存テスト\nline2\nline3"])
        await sleep(0.3)
        tab = await activeTab()
        check("edit_marks_dirty", tab["dirty"] as? Bool == true, "dirty=\(String(describing: tab["dirty"]))")
        await key(Key.s, [.command], chars: "s")
        await sleep(0.5)
        tab = await activeTab()
        check("save_overwrites", fileText(saved) == "保存テスト\nline2\nline3" && tab["dirty"] as? Bool == false,
              "file=\(String(describing: fileText(saved))) dirty=\(String(describing: tab["dirty"]))")

        // 外で書き換わった: 未保存の変更が無ければ、出し直したときに読み直す
        try? "外で書き換え\n".write(toFile: saved, atomically: true, encoding: .utf8)
        await hideAndShow()
        var ws = await workspace()
        check("reload_when_clean", ws.value == "外で書き換え\n" && docs.currentAlert == nil, "value=\(ws.value)")

        // 未保存の変更があるときは聞く →「自分の変更を残す」
        panel.bridge.send(["type": "setContent", "value": "自分の変更"])
        await sleep(0.3)
        try? "外2\n".write(toFile: saved, atomically: true, encoding: .utf8)
        await hideAndShow()
        check("conflict_asks", docs.currentAlert != nil, "alert=\(docs.currentAlert?.messageText ?? "nil")")
        await clickAlert(1, "conflict_keep")
        ws = await workspace()
        tab = await activeTab()
        check("conflict_keep_mine", ws.value == "自分の変更" && tab["dirty"] as? Bool == true, "value=\(ws.value)")
        await hideAndShow()
        check("conflict_not_asked_twice", docs.currentAlert == nil, "alert=\(docs.currentAlert?.messageText ?? "nil")")

        // 未保存の変更があるファイルを Cmd+W →「キャンセル」で残る、「保存しない」で閉じる（ファイルは書き換えない）
        await key(Key.w, [.command], chars: "w")
        check("close_dirty_asks", docs.currentAlert != nil, "alert=\(docs.currentAlert?.messageText ?? "nil")")
        await clickAlert(2, "close_cancel")
        tab = await activeTab()
        check("close_cancel_keeps_tab", tab["path"] as? String == saved, "tab=\(tab)")
        await key(Key.w, [.command], chars: "w")
        await clickAlert(1, "close_discard")
        tab = await activeTab()
        check("close_discard", tab["path"] as? String != saved && fileText(saved) == "外2\n", "tab=\(tab) file=\(String(describing: fileText(saved)))")

        // 次の --selftest-restore で確かめる状態を作る: メモ・CRLF のファイル・未保存の変更があるファイル
        let crlf = dataDir.appendingPathComponent("files/crlf.txt").path
        try? FileManager.default.removeItem(atPath: crlf)
        panel.bridge.send(["type": "setContent", "value": "復元テストのメモ\n二行目"])
        await key(Key.n, [.command], chars: "n")
        panel.bridge.send(["type": "setContent", "value": "c1\r\nc2\r\n"])
        await sleep(0.3)
        docs.savePathOverride = crlf
        await key(Key.s, [.command], chars: "s")
        await sleep(0.5)
        let crlfBytes = (try? Data(contentsOf: URL(fileURLWithPath: crlf))) ?? Data()
        check("save_keeps_crlf", crlfBytes == Data("c1\r\nc2\r\n".utf8), "bytes=\(crlfBytes.count)")
        await key(Key.n, [.command], chars: "n")
        panel.bridge.send(["type": "setContent", "value": "最初の中身\n"])
        await sleep(0.3)
        docs.savePathOverride = saved
        await key(Key.s, [.command], chars: "s")
        await sleep(0.5)
        panel.bridge.send(["type": "setContent", "value": "未保存の変更\n"])
        await sleep(0.6)
        let session = fileText(dataDir.appendingPathComponent("session.json").path) ?? ""
        check("session_written", session.contains("復元テストのメモ") && session.contains("未保存の変更") && !session.contains("c1\\r\\nc2"),
              "bytes=\(session.utf8.count)")
    }

    /// 前回の --selftest の終わりの状態（メモ・crlf.txt・未保存の変更がある saved.md）が戻っているか
    func runRestore() async {
        Log.write("selftest.start", "restore")
        await withCheckedContinuation { c in panel.bridge.whenReady { c.resume() } }
        await sleep(0.5)
        panel.show()
        await sleep(0.8)
        let ws = await workspace()
        let all = ws.groups.flatMap { tabs($0) }
        let titles = all.compactMap { $0["title"] as? String }
        check("restore_tabs", titles.contains("復元テストのメモ") && titles.contains("crlf.txt") && titles.contains("saved.md"), "titles=\(titles)")
        let savedTab = all.first { $0["title"] as? String == "saved.md" }
        check("restore_dirty_file", savedTab?["dirty"] as? Bool == true, "tab=\(String(describing: savedTab))")
        check("restore_cursor_tab", ws.value == "未保存の変更\n", "value=\(ws.value)")

        // crlf.txt は起動前に BOM を付けてある（VERIFY.md の手順）。未保存の変更が無いのでディスクの中身で戻る
        let crlf = dataDir.appendingPathComponent("files/crlf.txt").path
        await key(Key.one, [.command], chars: "1")
        for _ in 0..<20 {
            if (await activeTab())["title"] as? String == "crlf.txt" { break }
            await key(Key.tab, [.control], chars: "\t")
        }
        let value = (await workspace()).value
        check("restore_crlf_from_disk", value == "c1\r\nc2\r\n", "value=\(value.debugDescription)")
        panel.bridge.send(["type": "setContent", "value": "c1\r\nc2\r\nc3\r\n"])
        await sleep(0.3)
        await key(Key.s, [.command], chars: "s")
        await sleep(0.5)
        let bytes = (try? Data(contentsOf: URL(fileURLWithPath: crlf))) ?? Data()
        let expected = Data([0xEF, 0xBB, 0xBF]) + Data("c1\r\nc2\r\nc3\r\n".utf8)
        check("save_keeps_bom_and_crlf", bytes == expected, "bytes=\(bytes.map { String(format: "%02x", $0) }.joined())")

        // 落ちたときのために: 書き換えてから 1 秒待つと session.json に入っている（このあと kill -9 する）
        panel.bridge.send(["type": "setContent", "value": "kill-9 の前に書いた\r\n"])
        await sleep(1.0)
        Log.write("selftest.done", "restore ok=\(ok) ng=\(ng)")
    }

    // MARK: - 道具

    private func check(_ name: String, _ passed: Bool, _ detail: String) {
        if passed { ok += 1 } else { ng += 1 }
        Log.write("selftest.\(name)", "\(passed ? "OK" : "NG") \(detail)")
    }

    private func sleep(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private enum Key {
        static let a: UInt16 = 0, s: UInt16 = 1, x: UInt16 = 7, c: UInt16 = 8, v: UInt16 = 9
        static let w: UInt16 = 13, one: UInt16 = 18, o: UInt16 = 31, p: UInt16 = 35, backslash: UInt16 = 42
        static let n: UInt16 = 45, tab: UInt16 = 48, escape: UInt16 = 53
        static let h: UInt16 = 4, y: UInt16 = 16, t: UInt16 = 17, enter: UInt16 = 36
        static let right: UInt16 = 124, down: UInt16 = 125
    }

    private func key(_ code: UInt16, _ mods: NSEvent.ModifierFlags = [], chars: String? = nil) async {
        var flags = mods
        var characters = chars ?? ""
        switch code {
        case Key.down:
            characters = String(Character(UnicodeScalar(NSDownArrowFunctionKey)!))
            flags.formUnion([.numericPad, .function])
        case Key.right:
            characters = String(Character(UnicodeScalar(NSRightArrowFunctionKey)!))
            flags.formUnion([.numericPad, .function])
        case Key.escape:
            characters = "\u{1b}"
        default:
            break
        }
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: flags,
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: panel.panel.windowNumber, context: nil,
                characters: characters, charactersIgnoringModifiers: characters,
                isARepeat: false, keyCode: code) else { continue }
            NSApp.sendEvent(event)
        }
        await sleep(0.3)
    }

    private struct WindowInfo {
        let number: Int
        let owner: String
        let layer: Int
    }

    /// 画面に出ているウィンドウを前から順に（ウィンドウの持ち主と番号だけなら許可は要らない）
    private func onscreenWindowOrder() -> [WindowInfo] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        return list.map {
            WindowInfo(number: $0[kCGWindowNumber as String] as? Int ?? -1,
                       owner: $0[kCGWindowOwnerName as String] as? String ?? "?",
                       layer: $0[kCGWindowLayer as String] as? Int ?? 0)
        }
    }

    private func savePasteboard() -> [NSPasteboardItem] {
        (NSPasteboard.general.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
    }

    private func restorePasteboard(_ items: [NSPasteboardItem]) {
        NSPasteboard.general.clearContents()
        if !items.isEmpty { NSPasteboard.general.writeObjects(items) }
    }
}
extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
#endif
