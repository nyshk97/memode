import Foundation
import ServiceManagement

/// ログイン時に起動する（システム設定のログイン項目に Memode が出る）。
/// 左 Shift のダブルタップは動いていないと効かないので、常用版は初回の起動で一度だけ ON にする。
/// 自分で OFF にしたら戻さない（一度 ON にしたことを UserDefaults に覚えておく）
enum LoginItem {
    private static let offeredKey = "loginItemEnabledOnce"

    enum State: Equatable {
        case enabled
        case disabled
        /// 登録はしたが、システム設定のログイン項目で許可されていない
        case requiresApproval
    }

    static var state: State {
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        default: return .disabled
        }
    }

    static func setEnabled(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            Log.write("login_item.set", "on=\(on) state=\(state)")
        } catch {
            Log.write("login_item.failed", "on=\(on) \(error)")
        }
    }

    /// 起動時に ON にするか。dev 版は ON にしない（常用版と一緒に立ち上がると、ダブルタップに両方が反応する）
    static func shouldEnableOnLaunch(isDev: Bool, enabledOnce: Bool) -> Bool {
        !isDev && !enabledOnce
    }

    static func enableOnFirstLaunchIfNeeded(defaults: UserDefaults = .standard) {
        guard shouldEnableOnLaunch(isDev: AppInfo.isDev, enabledOnce: defaults.bool(forKey: offeredKey)) else { return }
        defaults.set(true, forKey: offeredKey)
        setEnabled(true)
    }

    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
