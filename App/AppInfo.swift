import Foundation

/// dev 版と常用版で分けるもの（ログ・データの置き場）と、アプリの情報
enum AppInfo {
    #if DEBUG
    static let isDev = true
    static let logDirName = "memode-dev"
    static let dataDirName = "Memode-dev"
    /// v0.1.1 までの置き場（起動時に dataDirectory へ移す）
    static let legacyDataDirName = "Memode-dev"
    #else
    static let isDev = false
    static let logDirName = "memode"
    static let dataDirName = "Memode"
    // "Memode" でなかったのは、大文字・小文字を区別しないディスクではリポジトリの ~/memode と同じ場所になるため
    static let legacyDataDirName = "Memode Data"
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

    /// dev 版の `--data-dir <path>`（自走の検証が手元のメモを書き潰さないように）
    static let dataDirOverride: URL? = {
        #if DEBUG
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--data-dir"), i + 1 < args.count {
            return URL(fileURLWithPath: args[i + 1], isDirectory: true)
        }
        #endif
        return nil
    }()

    /// セッション・最近使ったファイル・設定。どれもアプリが書くものなので、ホームの直下でなく Application Support に置く
    /// （~/Library は Cmd+P の一覧にも出ない）。Finder で見たいときはメニューバーの「データのフォルダを開く」
    static let dataDirectory: URL = dataDirOverride ?? FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/\(dataDirName)", isDirectory: true)

    static let legacyDataDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(legacyDataDirName, isDirectory: true)

    enum MigrationResult: Equatable {
        case moved
        /// 古い置き場が無い（移し終わっている・初めての起動）
        case nothingToMove
        /// 両方ある。どちらが新しいか決められないので、古い方には触らない
        case bothExist
        case failed(String)
    }

    /// 古い置き場があり、新しい置き場がまだ無ければ、フォルダごと移す（同じディスクの中なので名前の付け替えで済む）
    static func migrateLegacyData(from old: URL, to new: URL) -> MigrationResult {
        let fm = FileManager.default
        guard fm.fileExists(atPath: old.path) else { return .nothingToMove }
        guard !fm.fileExists(atPath: new.path) else { return .bothExist }
        do {
            try fm.createDirectory(at: new.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: old, to: new)
            return .moved
        } catch {
            return .failed("\(error)")
        }
    }
}
