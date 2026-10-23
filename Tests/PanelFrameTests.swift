import XCTest

final class PanelFrameTests: XCTestCase {
    // 外付けの画面が内蔵の右にある並び（画面の座標は左下が原点。メニューバーと Dock の分だけ visible が狭い）
    let screen = CGRect(x: 1512, y: 0, width: 2560, height: 1440)
    var visible: CGRect { CGRect(x: 1512, y: 0, width: 2560, height: 1415) }

    func testDefaultIsCenteredAndCapped() {
        let f = PanelFrameRules.defaultFrame(visible: visible)
        XCTAssertEqual(f.size, CGSize(width: 1400, height: 900))
        XCTAssertEqual(f.midX, visible.midX, accuracy: 1)
        XCTAssertEqual(f.midY, visible.midY, accuracy: 1)
    }

    func testRoundTripThroughRelative() {
        let frame = CGRect(x: 1600, y: 200, width: 900, height: 600)
        let saved = PanelFrameRules.relative(frame, screenFrame: screen)
        XCTAssertEqual(saved, CGRect(x: 88, y: 200, width: 900, height: 600))
        XCTAssertEqual(PanelFrameRules.restore(saved, screenFrame: screen, visible: visible), frame)
    }

    /// 画面の並びを変えて（外付けを左に置き直して）画面の座標が動いても、画面の中の同じ場所に出る
    func testFollowsScreenWhenArrangementChanges() {
        let saved = CGRect(x: 88, y: 200, width: 900, height: 600)
        let moved = CGRect(x: -2560, y: 0, width: 2560, height: 1440)
        let f = PanelFrameRules.restore(saved, screenFrame: moved, visible: CGRect(x: -2560, y: 0, width: 2560, height: 1415))
        XCTAssertEqual(f.origin, CGPoint(x: -2472, y: 200))
    }

    /// 解像度を下げた・覚えた場所が今の画面からはみ出す: 縮めて内側に寄せる
    func testClampsIntoVisibleFrame() {
        let saved = CGRect(x: 2000, y: 1200, width: 3000, height: 800)
        let f = PanelFrameRules.restore(saved, screenFrame: screen, visible: visible)
        XCTAssertEqual(f.width, visible.width)
        XCTAssertEqual(f.maxX, visible.maxX)
        XCTAssertEqual(f.maxY, visible.maxY)
        XCTAssertTrue(visible.contains(f))
    }

    /// キャレットの行の左端がマウスの位置に、行の下端がマウスの少し上に来る
    func testCompactFramePutsCaretAtAnchor() {
        let caret = CGRect(x: 60, y: 100, width: 0, height: 18)
        let anchor = CGPoint(x: 2500, y: 700)
        let f = PanelFrameRules.compactFrame(size: CGSize(width: 720, height: 480), caret: caret, anchor: anchor, visible: visible)
        XCTAssertEqual(f.size, CGSize(width: 720, height: 480))
        XCTAssertEqual(f.minX + caret.minX, anchor.x)
        XCTAssertEqual(f.maxY - caret.maxY, anchor.y + PanelFrameRules.caretGap)
    }

    /// マウスが画面の隅にあるときは、画面の中に収める
    func testCompactFrameClampsIntoVisible() {
        let caret = CGRect(x: 60, y: 100, width: 0, height: 18)
        for anchor in [CGPoint(x: visible.maxX - 2, y: visible.minY + 2), CGPoint(x: visible.minX + 1, y: visible.maxY - 1)] {
            let f = PanelFrameRules.compactFrame(size: CGSize(width: 720, height: 480), caret: caret, anchor: anchor, visible: visible)
            XCTAssertTrue(visible.contains(f), "\(anchor) -> \(f)")
        }
    }

    /// 画面より大きい大きさを覚えていても、画面に収まる大きさに縮める
    func testCompactFrameShrinksToVisible() {
        let small = CGRect(x: 0, y: 0, width: 600, height: 400)
        let f = PanelFrameRules.compactFrame(size: CGSize(width: 720, height: 480), caret: CGRect(x: 60, y: 100, width: 0, height: 18),
                                             anchor: CGPoint(x: 300, y: 200), visible: small)
        XCTAssertEqual(f, small)
    }

    /// 縮めるときの anchor: 今のキャレットの場所に、縮めた後のキャレットが来る
    func testAnchorKeepsCaretInPlace() {
        let big = CGRect(x: 1700, y: 200, width: 1400, height: 900)
        let caretInBig = CGRect(x: 80, y: 300, width: 0, height: 18)
        let anchor = PanelFrameRules.anchor(caret: caretInBig, frame: big)
        let caretInSmall = CGRect(x: 80, y: 140, width: 0, height: 18)
        let f = PanelFrameRules.compactFrame(size: CGSize(width: 720, height: 480), caret: caretInSmall, anchor: anchor, visible: visible)
        XCTAssertEqual(f.minX + caretInSmall.minX, big.minX + caretInBig.minX)
        XCTAssertEqual(f.maxY - caretInSmall.maxY, big.maxY - caretInBig.maxY)
    }

    /// 小さいときの大きさも画面ごとに覚え、元に戻すと両方消える。v1.0.1 までの window.json（compact が無い）も読める
    func testStoreCompactSize() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("memode-frame-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(#"{"screens":{"A":{"x":10,"y":20,"width":800,"height":500}}}"#.utf8).write(to: dir.appendingPathComponent("window.json"))
        let store = PanelFrameStore(directory: dir)
        XCTAssertEqual(store.frame(for: "A"), CGRect(x: 10, y: 20, width: 800, height: 500))
        XCTAssertNil(store.compactSize(for: "A"))
        store.setCompactSize(CGSize(width: 640, height: 420), for: "A")
        let reopened = PanelFrameStore(directory: dir)
        XCTAssertEqual(reopened.compactSize(for: "A"), CGSize(width: 640, height: 420))
        XCTAssertEqual(reopened.frame(for: "A"), CGRect(x: 10, y: 20, width: 800, height: 500))
        reopened.remove(screenID: "A")
        let again = PanelFrameStore(directory: dir)
        XCTAssertNil(again.compactSize(for: "A"))
        XCTAssertNil(again.frame(for: "A"))
    }

    func testStorePersistsPerScreen() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("memode-frame-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = PanelFrameStore(directory: dir)
        XCTAssertNil(store.frame(for: "A"))
        store.set(CGRect(x: 10, y: 20, width: 800, height: 500), for: "A")
        store.set(CGRect(x: 30, y: 40, width: 1000, height: 700), for: "B")
        let reopened = PanelFrameStore(directory: dir)
        XCTAssertEqual(reopened.frame(for: "A"), CGRect(x: 10, y: 20, width: 800, height: 500))
        XCTAssertEqual(reopened.frame(for: "B"), CGRect(x: 30, y: 40, width: 1000, height: 700))
        reopened.remove(screenID: "A")
        let again = PanelFrameStore(directory: dir)
        XCTAssertNil(again.frame(for: "A"))
        XCTAssertNotNil(again.frame(for: "B"))
    }

    func testBrokenFileIsIgnored() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("memode-frame-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("{ broken".utf8).write(to: dir.appendingPathComponent("window.json"))
        XCTAssertNil(PanelFrameStore(directory: dir).frame(for: "A"))
    }
}
