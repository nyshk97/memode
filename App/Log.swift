import Foundation

/// open 経由の起動では stdout が取れないので、ファイルに追記する。
/// イベント名は固定の文字列にして grep で検証できるようにする（例: `panel.show`）
enum Log {
    private static let queue = DispatchQueue(label: "memode.log")
    private static let fileURL = AppInfo.logDirectory.appendingPathComponent("memode.log")
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    static func write(_ event: String, _ detail: String = "") {
        let line = "\(formatter.string(from: Date())) \(event)\(detail.isEmpty ? "" : " \(detail)")\n"
        queue.async {
            let fm = FileManager.default
            if !fm.fileExists(atPath: fileURL.path) {
                try? fm.createDirectory(at: AppInfo.logDirectory, withIntermediateDirectories: true)
                fm.createFile(atPath: fileURL.path, contents: nil)
            }
            guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        }
    }
}
