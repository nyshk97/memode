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
