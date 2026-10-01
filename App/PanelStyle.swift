import Foundation

/// パネルの方式。どちらにするかは Phase 2 の確認（日本語入力）で決める。
/// - nonactivating: アプリをアクティブにせず、パネルだけがキー入力を受ける（Spotlight と同じ）
/// - activating: 普通にアプリをアクティブにする
enum PanelStyle: String, CaseIterable {
    case nonactivating
    case activating

    private static let defaultsKey = "panelStyle"

    static var current: PanelStyle {
        get {
            #if DEBUG
            if let i = CommandLine.arguments.firstIndex(of: "--panel-style"),
               i + 1 < CommandLine.arguments.count,
               let style = PanelStyle(rawValue: CommandLine.arguments[i + 1]) {
                return style
            }
            #endif
            return UserDefaults.standard.string(forKey: defaultsKey).flatMap(PanelStyle.init) ?? .nonactivating
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey) }
    }
}

/// ポップアップを隠すきっかけ
enum HideReason: String {
    /// 左 Shift のダブルタップ・メニューの「表示 / 隠す」
    case toggle
    /// 最後のタブを閉じた
    case lastTabClosed
    /// フォーカスがアプリの外に移った（外をクリックした等）
    case focusLost
    /// アップデートの確認の画面を出す（ポップアップは .floating なので、出したままだと画面が後ろに隠れる）
    case checkForUpdates
}

/// 隠す・フォーカスを戻すの決まり（ユニットテストする）
enum HideRules {
    /// パネルがキーを失ったときに隠すか。キーが自分のアプリの別のウィンドウ（ファイル選択・保存・確認・シート）に
    /// 移っただけなら隠さない（隠すと Cmd+O や Cmd+S のたびに隠れてしまう）
    static func shouldHideOnResignKey(keyWindowIsOurs: Bool, hasAttachedSheet: Bool, appIsModal: Bool) -> Bool {
        !(keyWindowIsOurs || hasAttachedSheet || appIsModal)
    }

    /// 隠したあと直前のアプリにフォーカスを戻すか（自分で隠した: ダブルタップ・最後のタブを閉じた）。
    /// 外のクリックで隠れたときは、クリックした先のアプリにフォーカスが移っているので何もしない。
    /// nonactivating はそもそも前面のアプリを切り替えていないので戻す必要がない
    static func shouldRestorePreviousApp(reason: HideReason, style: PanelStyle) -> Bool {
        (reason == .toggle || reason == .lastTabClosed) && style == .activating
    }
}

/// 画面に出ているウィンドウ 1 枚（CGWindowListCopyWindowInfo から。持ち主・レイヤー・大きさだけなら画面収録の許可は要らない）
struct ScreenWindow: Equatable {
    var bundleID: String?
    var layer: Int
    var size: CGSize
}

/// mycast（クリップボード履歴を持つランチャー）にキー入力を貸すときの決まり（ユニットテストする）。
/// ⌃L で mycast が前に出ると、パネルは key を失う。そのとき隠さずに待ち、mycast が閉じたあと
/// `memode://focus`・`memode://paste` で返ってきたら key を取り直す（mycast 側は ~/mycast の CLAUDE.md）
enum LendRules {
    static let launcherBundleIDs: Set<String> = ["io.github.nyshk97.mycast", "io.github.nyshk97.mycast.dev"]
    /// NSWindow.Level.floating（mycast のパネルのレベル）
    static let floatingLayer = 3
    /// mycast のパネルが消えてから、返ってくるのを待つ長さ。mycast は元のアプリが前面になるのを最大 1.05 秒待ってから送るので、それより十分長くする
    static let returnTimeout: TimeInterval = 2.5

    static func isLauncher(_ bundleID: String?) -> Bool {
        bundleID.map(launcherBundleIDs.contains) ?? false
    }

    /// mycast のパネルか。メニューバーのアイテム（レイヤー 25）や「コピーしました」の通知（.statusBar）はレイヤーで外す
    static func isLauncherPanel(_ w: ScreenWindow, isLauncher: (String?) -> Bool = isLauncher) -> Bool {
        isLauncher(w.bundleID) && w.layer == floatingLayer && w.size.width >= 200 && w.size.height >= 30
    }

    /// 出すときに前面のアプリを「元のアプリ」として覚えるか。自分は覚えない（activating のとき）。
    /// mycast も覚えない（mycast から返ってきたとき、元のアプリがまだ前面になっていなければ mycast が前面のことがある。
    /// 覚えてしまうと、次に貸したとき元のアプリが前面に戻った瞬間に「他のアプリ」として隠れる）
    static func shouldRememberFront(isOwn: Bool, isLauncher: Bool) -> Bool {
        !isOwn && !isLauncher
    }

    /// 前面のアプリが何か
    enum Front {
        /// mycast
        case launcher
        /// memode を出したときの前面（mycast が閉じたあと、まずここが前面に戻る）
        case home
        /// memode 自身
        case own
        case other
    }

    enum ResignDecision: String {
        /// 自分の別のウィンドウ（ファイル選択・確認等）に移っただけ
        case keep
        /// mycast に貸す（隠さない）
        case lend
        case hide
        /// まだ決められない（前面のアプリの切り替わりは遅れて届く）。少し待ってからもう一度決める
        case wait
    }

    /// パネルが key を失ったとき。前面のアプリが元のまま（`home`）なのは、元のアプリをクリックしたか、
    /// mycast への切り替わりがまだ届いていないかのどちらか。なので一度だけ待つ
    static func onResignKey(keyWindowIsOurs: Bool, hasAttachedSheet: Bool, appIsModal: Bool,
                            launcherPanelVisible: Bool, front: Front, waited: Bool) -> ResignDecision {
        if !HideRules.shouldHideOnResignKey(keyWindowIsOurs: keyWindowIsOurs, hasAttachedSheet: hasAttachedSheet, appIsModal: appIsModal) {
            return .keep
        }
        if launcherPanelVisible || front == .launcher { return .lend }
        if front == .other || waited { return .hide }
        return .wait
    }

    /// 貸している間に別のアプリが前面になったとき隠すか。mycast と元のアプリ（mycast が閉じるとまずここに戻る）は待つ
    static func shouldHideOnActivate(_ front: Front) -> Bool {
        front == .other
    }

    /// 貸している間、mycast のパネルを見張る。消えてから returnTimeout たっても返ってこなければ隠す
    static func tick(launcherPanelVisible: Bool, goneAt: Date?, now: Date) -> (goneAt: Date?, hide: Bool) {
        if launcherPanelVisible { return (nil, false) }
        let gone = goneAt ?? now
        return (gone, now.timeIntervalSince(gone) >= returnTimeout)
    }
}
