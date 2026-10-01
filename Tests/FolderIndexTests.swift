import XCTest

final class FolderIndexTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("memode-index-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func touch(_ rel: String) throws {
        let url = dir.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: url)
    }

    private func names() -> Set<String> {
        let root = dir.standardizedFileURL.path
        return Set(FolderIndex.files(in: dir.path).map { String(($0 as NSString).standardizingPath.dropFirst(root.count + 1)) })
    }

    func testWalkSkipsHeavyDirectories() throws {
        try touch("a.swift")
        try touch("sub/b.md")
        try touch("node_modules/pkg/index.js")
        try touch(".git/HEAD")
        XCTAssertEqual(names(), ["a.swift", "sub/b.md"])
    }

    func testGitRepositoryUsesGitIgnore() throws {
        try touch("a.swift")
        try touch("ignored.log")
        try touch("sub/new.txt")
        try Data("*.log\n".utf8).write(to: dir.appendingPathComponent(".gitignore"))
        let git = Process()
        git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        git.arguments = ["-C", dir.path, "init", "-q"]
        try git.run()
        git.waitUntilExit()
        // コミットしていない（untracked）ファイルも出す。.gitignore で除いたものは出さない
        XCTAssertEqual(names(), [".gitignore", "a.swift", "sub/new.txt"])
    }
}
