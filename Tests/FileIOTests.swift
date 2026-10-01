import XCTest

final class FileIOTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("memode-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func path(_ name: String) -> String { dir.appendingPathComponent(name).path }

    func testBOMAndCRLFAreKeptByteForByte() throws {
        let original = Data([0xEF, 0xBB, 0xBF]) + Data("一行目\r\n二行目\r\n".utf8)
        try original.write(to: URL(fileURLWithPath: path("a.txt")))
        let snapshot = try FileIO.read(path("a.txt"))
        XCTAssertTrue(snapshot.bom)
        XCTAssertEqual(snapshot.content, "一行目\r\n二行目\r\n") // BOM は中身に入らない・CRLF は残る
        _ = try FileIO.write(path("a.txt"), content: snapshot.content, bom: snapshot.bom)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path("a.txt"))), original)
    }

    func testNoBOMStaysWithoutBOM() throws {
        try Data("x\n".utf8).write(to: URL(fileURLWithPath: path("b.txt")))
        let snapshot = try FileIO.read(path("b.txt"))
        XCTAssertFalse(snapshot.bom)
        _ = try FileIO.write(path("b.txt"), content: snapshot.content + "y\n", bom: false)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path("b.txt"))), Data("x\ny\n".utf8))
    }

    func testRejectsNonUTF8AndBinaryAndMissing() throws {
        // Shift_JIS の「あ」
        try Data([0x82, 0xA0]).write(to: URL(fileURLWithPath: path("sjis.txt")))
        XCTAssertThrowsError(try FileIO.read(path("sjis.txt"))) { XCTAssertEqual($0 as? FileIO.ReadError, .notUTF8) }
        try Data([0x41, 0x00, 0x42]).write(to: URL(fileURLWithPath: path("bin")))
        XCTAssertThrowsError(try FileIO.read(path("bin"))) { XCTAssertEqual($0 as? FileIO.ReadError, .binary) }
        XCTAssertThrowsError(try FileIO.read(path("none"))) { XCTAssertEqual($0 as? FileIO.ReadError, .notFound) }
    }

    func testSavingThroughSymlinkKeepsTheLink() throws {
        // ~/.zshrc → Dropbox の dotfiles のような形
        try Data("old\n".utf8).write(to: URL(fileURLWithPath: path("real.txt")))
        try FileManager.default.createSymbolicLink(atPath: path("link.txt"), withDestinationPath: "real.txt")
        let snapshot = try FileIO.read(path("link.txt"))
        XCTAssertEqual(snapshot.content, "old\n")
        let base = try FileIO.write(path("link.txt"), content: "new\n", bom: false)
        let attrs = try FileManager.default.attributesOfItem(atPath: path("link.txt"))
        XCTAssertEqual(attrs[.type] as? FileAttributeType, .typeSymbolicLink)
        XCTAssertEqual(try String(contentsOfFile: path("real.txt"), encoding: .utf8), "new\n")
        // 目印はリンク先のもの（リンク自身の大きさ・日付ではない）なので、書いた直後は「変わっていない」
        XCTAssertNil(try FileIO.changedSince(path("link.txt"), base: base))
    }

    func testSavingKeepsExecutableBit() throws {
        try Data("#!/bin/sh\n".utf8).write(to: URL(fileURLWithPath: path("run.sh")))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path("run.sh"))
        _ = try FileIO.write(path("run.sh"), content: "#!/bin/sh\necho hi\n", bom: false)
        let mode = try FileManager.default.attributesOfItem(atPath: path("run.sh"))[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o755)
    }

    func testChangedSince() throws {
        let base = try FileIO.write(path("c.txt"), content: "v1", bom: false)
        XCTAssertNil(try FileIO.changedSince(path("c.txt"), base: base))
        // 中身が変わった
        try Data("v2-longer".utf8).write(to: URL(fileURLWithPath: path("c.txt")))
        XCTAssertEqual(try FileIO.changedSince(path("c.txt"), base: base)?.content, "v2-longer")
        // 日付だけ変わって中身が同じなら、変わっていない扱い
        let base2 = try FileIO.write(path("c.txt"), content: "same", bom: false)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 60)], ofItemAtPath: path("c.txt"))
        XCTAssertNil(try FileIO.changedSince(path("c.txt"), base: base2))
        // 消えた
        try FileManager.default.removeItem(atPath: path("c.txt"))
        XCTAssertThrowsError(try FileIO.changedSince(path("c.txt"), base: base2)) { XCTAssertEqual($0 as? FileIO.ReadError, .notFound) }
    }
}
