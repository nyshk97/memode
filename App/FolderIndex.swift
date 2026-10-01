import Foundation

/// Cmd+P の候補にするファイルの一覧。
/// - ホーム（~）の下は既定で全部。ただし重い・関係ない場所（homeExcluded・隠しディレクトリ・skippedDirectories）は入らない
/// - git のリポジトリの中は `git ls-files`（.gitignore で除いたものは出ない。コミット前のファイルは出る）
/// - それ以外は走査する（シンボリックリンクはたどらない。.app などのパッケージの中には入らない）
enum FolderIndex {
    static let maxFiles = 300_000
    static let maxDepth = 14
    /// ホーム直下で入らない場所（~/Library は CloudStorage（Dropbox 等）だけ別に入る）。
    /// ~/OrbStack は Docker のボリュームが見えていて 70 万ファイル近くある（2026-10-01 の実測）
    static let homeExcluded: Set<String> = ["Library", "Applications", "Music", "Movies", "Pictures", "OrbStack"]
    /// どこにあっても入らないディレクトリ（重い・生成物・秘密鍵）
    static let skippedDirectories: Set<String> = [
        ".git", ".svn", ".hg", "node_modules", ".build", "build", "dist", "DerivedData", "Pods", "vendor",
        ".next", ".nuxt", ".turbo", ".parcel-cache", ".venv", "venv", "__pycache__", ".mypy_cache", ".pytest_cache", ".tox",
        ".cache", ".idea", ".gradle", "target", ".terraform", ".dart_tool", ".pnpm-store", ".yarn", ".expo", ".angular",
        ".ssh", ".gnupg", ".Trash",
    ]

    /// フォルダの中のファイルの絶対パス（登録フォルダ・テスト用）
    static func files(in folder: String) -> [String] {
        if let listed = gitFiles(in: folder) { return listed }
        var result: [String] = []
        walk(URL(fileURLWithPath: folder, isDirectory: true).standardizedFileURL, excludedTopLevel: [], useGitAtRoot: true, into: &result)
        return result
    }

    /// ホームの下全部（と ~/Library/CloudStorage の下）
    static func homeFiles(home: URL) -> [String] {
        var result: [String] = []
        let root = home
        // ホーム自体が git のリポジトリでも git に任せない（除く場所まで git がたどってしまう）
        walk(root, excludedTopLevel: homeExcluded, useGitAtRoot: false, into: &result)
        // 名前だけ取ってつなぐ（URL で列挙すると /private/var のように書き方が変わることがある）
        let cloud = root.path + "/Library/CloudStorage"
        if let providers = try? FileManager.default.contentsOfDirectory(atPath: cloud) {
            for name in providers.sorted() where !name.hasPrefix(".") && result.count < maxFiles {
                walk(URL(fileURLWithPath: cloud + "/" + name, isDirectory: true), excludedTopLevel: [], useGitAtRoot: true, into: &result)
            }
        }
        return result
    }

    /// 本物の git の場所。/usr/bin/git は xcrun を通す入口で、アプリから初めて呼ぶと数秒かかった（5.2 秒の実測）。
    /// 一度だけ `xcrun --find git` で場所を調べて使い回す（起動時に裏で warmUp を呼んでおく）
    private static let gitPath: String = {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["--find", "git"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return "/usr/bin/git" }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return process.terminationStatus == 0 && FileManager.default.isExecutableFile(atPath: path) ? path : "/usr/bin/git"
    }()

    private static var warmedUp = false

    /// 起動時に裏で呼ぶ（indexQueue の上でだけ呼ぶ）
    static func warmUp() {
        guard !warmedUp else { return }
        warmedUp = true
        let started = Date()
        let path = gitPath
        Log.write("folder.git_path", "\(path) ms=\(Int(Date().timeIntervalSince(started) * 1000))")
    }

    private static func gitFiles(in folder: String) -> [String]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: gitPath)
        process.arguments = ["-C", folder, "ls-files", "--cached", "--others", "--exclude-standard", "-z"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil } // git のリポジトリでない
        let root = (folder as NSString).standardizingPath
        // `/` で終わるのは追跡していない入れ子のリポジトリ、`/` の無いディレクトリはサブモジュール。
        // 消したがまだコミットしていないファイルも返るので、在る「ファイル」だけ残す
        return data.split(separator: 0).prefix(maxFiles).compactMap { String(data: Data($0), encoding: .utf8) }
            .filter { !$0.hasSuffix("/") }
            .map { root + "/" + $0 }
            .filter { path in
                var isDir: ObjCBool = false
                return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && !isDir.boolValue
            }
    }

    /// 中に入らない「パッケージ」（Finder で 1 つのファイルに見えるディレクトリ）
    static let packageExtensions: Set<String> = [
        "app", "appex", "bundle", "framework", "plugin", "kext", "pkg", "photoslibrary", "xcodeproj", "xcworkspace", "xcassets",
    ]

    /// 起点からの相対パスでたどる。URL でたどると、起点の書き方（/var と /private/var 等）と返るパスがずれて、
    /// 深さの判定（ホーム直下で除く場所）とパスの突き合わせが狂った（自走の検証で OrbStack が一覧に入った）
    private static func walk(_ root: URL, excludedTopLevel: Set<String>, useGitAtRoot: Bool, into result: inout [String]) {
        let rootPath = root.path
        let fm = FileManager.default
        // root 自身が git のリポジトリなら丸ごと git に任せる
        if useGitAtRoot, fm.fileExists(atPath: rootPath + "/.git"), let listed = gitFiles(in: rootPath) {
            result.append(contentsOf: listed.prefix(maxFiles - result.count))
            return
        }
        guard let e = fm.enumerator(atPath: rootPath) else { return }
        while let rel = e.nextObject() as? String {
            let type = e.fileAttributes?[.type] as? FileAttributeType
            let name = (rel as NSString).lastPathComponent
            let path = rootPath + "/" + rel
            if type == .typeDirectory {
                let depth = e.level
                // 隠しディレクトリは、ホーム直下（~/.cache・~/.npm などツールのものがほとんど）だけ飛ばす。
                // それより深いもの（Dropbox の dotfiles/.claude 等）は自分で書いたものが多いので入れる
                let hiddenAtHomeTop = depth == 1 && !excludedTopLevel.isEmpty && name.hasPrefix(".")
                if (depth == 1 && excludedTopLevel.contains(name)) || hiddenAtHomeTop || skippedDirectories.contains(name)
                    || packageExtensions.contains((name as NSString).pathExtension.lowercased()) || depth >= maxDepth {
                    e.skipDescendants()
                } else if fm.fileExists(atPath: path + "/.git") {
                    // リポジトリの中は .gitignore に従う
                    e.skipDescendants()
                    if let listed = gitFiles(in: path) {
                        result.append(contentsOf: listed.prefix(maxFiles - result.count))
                    }
                }
            } else if type == .typeRegular, name != ".DS_Store" {
                // シンボリックリンク（.typeSymbolicLink）はたどらないし、候補にもしない
                result.append(path)
            }
            if result.count >= maxFiles { break }
        }
    }
}
