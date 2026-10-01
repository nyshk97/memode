import XCTest

final class DataMigrationTests: XCTestCase {
    private var dir: URL!
    private var old: URL { dir.appendingPathComponent("Memode Data") }
    private var new: URL { dir.appendingPathComponent("Library/Application Support/Memode") }

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("memode-migrate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func write(_ url: URL, _ text: String) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func read(_ url: URL) -> String? {
        (try? Data(contentsOf: url)).flatMap { String(data: $0, encoding: .utf8) }
    }

    func testMovesWholeFolderWhenNewIsMissing() throws {
        try write(old.appendingPathComponent("session.json"), "{\"memo\":\"未保存\"}")
        try write(old.appendingPathComponent("recent.json"), "[]")

        XCTAssertEqual(AppInfo.migrateLegacyData(from: old, to: new), .moved)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertEqual(read(new.appendingPathComponent("session.json")), "{\"memo\":\"未保存\"}")
        XCTAssertEqual(read(new.appendingPathComponent("recent.json")), "[]")

        // 2 回目は何もしない
        XCTAssertEqual(AppInfo.migrateLegacyData(from: old, to: new), .nothingToMove)
        XCTAssertEqual(read(new.appendingPathComponent("session.json")), "{\"memo\":\"未保存\"}")
    }

    func testLeavesBothAloneWhenBothExist() throws {
        try write(old.appendingPathComponent("session.json"), "old")
        try write(new.appendingPathComponent("session.json"), "new")

        XCTAssertEqual(AppInfo.migrateLegacyData(from: old, to: new), .bothExist)
        XCTAssertEqual(read(old.appendingPathComponent("session.json")), "old")
        XCTAssertEqual(read(new.appendingPathComponent("session.json")), "new")
    }

    func testNothingToMoveOnFirstLaunch() {
        XCTAssertEqual(AppInfo.migrateLegacyData(from: old, to: new), .nothingToMove)
        XCTAssertFalse(FileManager.default.fileExists(atPath: new.path))
    }
}
