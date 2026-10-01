import AppKit

/// アプリのショートカットを受けるメインメニュー。LSUIElement のアプリには標準で作られないので
/// コードで組む（画面には出ない）。WKWebView はキーをまず Web 側に渡し、JS が処理しなかったものが
/// ここに来るので、Monaco 側ではこれらのキーを使わない。
/// 編集メニュー（Cut・Copy・Paste・Select All）が無いと WKWebView で Cmd+C・V・X・A が効かない
enum MainMenu {
    /// メニューの操作。Phase 2 ではログに出すだけのものが多い（中身は Phase 4〜6）
    enum Action: String {
        case newTab = "new_tab"
        case open
        case quickOpen = "quick_open"
        case save
        case saveAs = "save_as"
        case closeTab = "close_tab"
        case selectTab = "select_tab"
        case nextTab = "next_tab"
        case previousTab = "previous_tab"
        case toggleSplit = "toggle_split"
        case chooseLanguage = "choose_language"
        case registerFolder = "register_folder"
        /// 出ている画面で覚えた位置と大きさを消して、既定に戻す
        case resetWindowFrame = "reset_window_frame"
        /// ステータスバーの版の表示を押したとき（メニューには置かない）
        case checkForUpdates = "check_for_updates"
    }

    static func build(target: AnyObject, action: Selector) -> NSMenu {
        let main = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Memode について", action: #selector(AppDelegate.showAbout(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Memode を終了", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        add(appMenu, to: main, title: "Memode")

        func item(_ title: String, _ act: Action, _ key: String, _ mods: NSEvent.ModifierFlags = .command, tag: Int = 0) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            i.target = target
            i.representedObject = act.rawValue
            i.tag = tag
            return i
        }

        let file = NSMenu()
        file.addItem(item("新しいタブ", .newTab, "n"))
        file.addItem(item("開く…", .open, "o"))
        file.addItem(item("ファイルを検索…", .quickOpen, "p"))
        file.addItem(item("フォルダを登録…", .registerFolder, ""))
        file.addItem(.separator())
        file.addItem(item("保存", .save, "s"))
        file.addItem(item("別名で保存…", .saveAs, "s", [.command, .shift]))
        file.addItem(.separator())
        file.addItem(item("タブを閉じる", .closeTab, "w"))
        add(file, to: main, title: "ファイル")

        let edit = NSMenu()
        edit.addItem(withTitle: "カット", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "コピー", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "ペースト", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "すべてを選択", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        add(edit, to: main, title: "編集")

        let view = NSMenu()
        view.addItem(item("左右に分割", .toggleSplit, "\\"))
        view.addItem(item("言語を選ぶ…", .chooseLanguage, ""))
        view.addItem(item("ウィンドウの位置とサイズを元に戻す", .resetWindowFrame, ""))
        view.addItem(.separator())
        view.addItem(item("次のタブ", .nextTab, "\t", .control))
        view.addItem(item("前のタブ", .previousTab, "\t", [.control, .shift]))
        for n in 1...9 {
            view.addItem(item("タブ \(n)", .selectTab, "\(n)", tag: n))
        }
        add(view, to: main, title: "表示")

        return main
    }

    private static func add(_ submenu: NSMenu, to main: NSMenu, title: String) {
        submenu.title = title
        let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        holder.submenu = submenu
        main.addItem(holder)
    }
}
