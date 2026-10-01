import XCTest

final class LoginItemTests: XCTestCase {
    func testEnablesOnlyOnFirstLaunchOfReleaseBuild() {
        XCTAssertTrue(LoginItem.shouldEnableOnLaunch(isDev: false, enabledOnce: false))
        // 一度 ON にした後は、自分で OFF にしていても戻さない
        XCTAssertFalse(LoginItem.shouldEnableOnLaunch(isDev: false, enabledOnce: true))
        // dev 版は常用版と一緒に立ち上がるとダブルタップに両方が反応するので ON にしない
        XCTAssertFalse(LoginItem.shouldEnableOnLaunch(isDev: true, enabledOnce: false))
    }

    func testDevBuildDoesNotRememberOrRegister() throws {
        let suite = "memode-login-item-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        LoginItem.enableOnFirstLaunchIfNeeded(defaults: defaults)
        XCTAssertFalse(defaults.bool(forKey: "loginItemEnabledOnce"))
    }
}
