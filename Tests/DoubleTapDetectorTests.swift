import XCTest

final class DoubleTapDetectorTests: XCTestCase {
    private let down: UInt = 0x20102 // Shift + 左 Shift のデバイスフラグ
    private let up: UInt = 0x100

    /// 左 Shift の「押す→離す」を流し、成立した回数を返す
    private func run(_ events: [(ShiftTapMapping.Kind, UInt16, UInt, TimeInterval)]) -> Int {
        var detector = DoubleTapDetector()
        return events.reduce(0) { count, e in
            count + (detector.handle(ShiftTapMapping.input(kind: e.0, keyCode: e.1, modifierFlags: e.2, timestamp: e.3)) ? 1 : 0)
        }
    }

    private func tap(_ t: TimeInterval, length: TimeInterval = 0.08, keyCode: UInt16 = 56) -> [(ShiftTapMapping.Kind, UInt16, UInt, TimeInterval)] {
        let flags: UInt = keyCode == 60 ? 0x20104 : down
        return [(.flagsChanged, keyCode, flags, t), (.flagsChanged, keyCode, up, t + length)]
    }

    func testDoubleTapFires() {
        XCTAssertEqual(run(tap(0) + tap(0.2)), 1)
    }

    func testSingleTapDoesNotFire() {
        XCTAssertEqual(run(tap(0)), 0)
    }

    func testGapTooLong() {
        XCTAssertEqual(run(tap(0) + tap(0.5)), 0)
    }

    func testLongPressIsNotATap() {
        XCTAssertEqual(run(tap(0, length: 0.5) + tap(0.7)), 0)
        XCTAssertEqual(run(tap(0) + tap(0.2, length: 0.5)), 0)
    }

    func testOtherKeyInBetweenCancels() {
        // Shift を押したまま A を打つ（大文字）→ もう一度 Shift
        let typing: [(ShiftTapMapping.Kind, UInt16, UInt, TimeInterval)] = [
            (.flagsChanged, 56, down, 0), (.keyDown, 0, down, 0.03), (.flagsChanged, 56, up, 0.06),
        ]
        XCTAssertEqual(run(typing + tap(0.15)), 0)
        XCTAssertEqual(run(tap(0) + [(.keyDown, 0, 0, 0.12)] + tap(0.2)), 0)
    }

    func testRightShiftIgnored() {
        XCTAssertEqual(run(tap(0, keyCode: 60) + tap(0.2, keyCode: 60)), 0)
        // 右 Shift を押したまま左 Shift を叩いても成立しない
        let withRight: UInt = down | 0x4
        XCTAssertEqual(run([(.flagsChanged, 56, withRight, 0), (.flagsChanged, 56, 0x20104, 0.08),
                            (.flagsChanged, 56, withRight, 0.2), (.flagsChanged, 56, 0x20104, 0.28)]), 0)
    }

    func testWithOtherModifierIgnored() {
        let withCommand: UInt = down | (1 << 20)
        XCTAssertEqual(run([(.flagsChanged, 56, withCommand, 0), (.flagsChanged, 56, 1 << 20, 0.08),
                            (.flagsChanged, 56, withCommand, 0.2), (.flagsChanged, 56, 1 << 20, 0.28)]), 0)
    }

    func testTripleTapFiresOnceThenRestarts() {
        // 3 回目は新しい 1 回目として扱い、4 回目で再び成立する
        XCTAssertEqual(run(tap(0) + tap(0.2) + tap(0.4)), 1)
        XCTAssertEqual(run(tap(0) + tap(0.2) + tap(0.4) + tap(0.6)), 2)
    }

    func testSlowFirstThenQuickPairStillFires() {
        // 間隔が空いた 2 回目は、新しい 1 回目になる
        XCTAssertEqual(run(tap(0) + tap(1.0) + tap(1.2)), 1)
    }
}

final class HideRulesTests: XCTestCase {
    func testHidesWhenFocusLeavesApp() {
        XCTAssertTrue(HideRules.shouldHideOnResignKey(keyWindowIsOurs: false, hasAttachedSheet: false, appIsModal: false))
    }

    func testStaysForOwnDialogs() {
        XCTAssertFalse(HideRules.shouldHideOnResignKey(keyWindowIsOurs: true, hasAttachedSheet: false, appIsModal: false))
        XCTAssertFalse(HideRules.shouldHideOnResignKey(keyWindowIsOurs: false, hasAttachedSheet: true, appIsModal: false))
        XCTAssertFalse(HideRules.shouldHideOnResignKey(keyWindowIsOurs: false, hasAttachedSheet: false, appIsModal: true))
    }

    func testRestorePreviousAppOnlyOnToggleWithActivating() {
        XCTAssertTrue(HideRules.shouldRestorePreviousApp(reason: .toggle, style: .activating))
        XCTAssertFalse(HideRules.shouldRestorePreviousApp(reason: .focusLost, style: .activating))
        XCTAssertFalse(HideRules.shouldRestorePreviousApp(reason: .toggle, style: .nonactivating))
        XCTAssertFalse(HideRules.shouldRestorePreviousApp(reason: .focusLost, style: .nonactivating))
        XCTAssertTrue(HideRules.shouldRestorePreviousApp(reason: .lastTabClosed, style: .activating))
        XCTAssertFalse(HideRules.shouldRestorePreviousApp(reason: .lastTabClosed, style: .nonactivating))
    }
}
