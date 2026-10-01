import Foundation

/// dev 版と常用版で分けるもの（ログ・データの置き場）と、アプリの情報
enum AppInfo {
    #if DEBUG
    static let isDev = true
    static let logDirName = "memode-dev"
    static let dataDirName = "Memode-dev"
    #else
    static let isDev = false
    static let logDirName = "memode"
    // "Memode" にしない: 大文字・小文字を区別しないディスクではリポジトリの ~/memode と同じ場所になり、データがリポジトリに書かれる
    static let dataDirName = "Memode Data"
    #endif

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }

    /// `memode://` / `memode-dev://`（project.yml で Debug と Release に分けている）
    static var urlScheme: String {
        Bundle.main.object(forInfoDictionaryKey: "MemodeURLScheme") as? String ?? "memode"
    }

    static let logDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/\(logDirName)", isDirectory: true)

    /// セッション・最近使ったファイル・設定。Finder で開ける場所に置く。
    /// dev 版は `--data-dir <path>` で差し替えられる（自走の検証が手元のメモを書き潰さないように）
    static let dataDirectory: URL = {
        #if DEBUG
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--data-dir"), i + 1 < args.count {
            return URL(fileURLWithPath: args[i + 1], isDirectory: true)
        }
        #endif
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(dataDirName, isDirectory: true)
    }()
}
