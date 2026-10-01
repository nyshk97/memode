import Foundation

/// セッション（タブ・メモの中身・カーソル・分割）を JSON で置く。中身の形は JS 側（web/src/session.ts）が決め、
/// Swift はファイルのパスと「外で書き換わったかの目印」だけを読む。
/// 壊れた JSON は捨てずに退避して、空で起動する
final class SessionStore {
    let directory: URL
    private var fileURL: URL { directory.appendingPathComponent("session.json") }
    private let queue = DispatchQueue(label: "memode.session")

    init(directory: URL) {
        self.directory = directory
    }

    /// 起動時に読む。ファイルのタブには、いまのディスクの中身（disk）か読めなかった理由（diskError）を付けて返す
    func load() -> [String: Any]? {
        guard let data = try? Data(contentsOf: fileURL) else {
            Log.write("session.none", fileURL.path)
            return nil
        }
        guard var session = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              var docs = session["docs"] as? [[String: Any]] else {
            moveAsideBroken()
            return nil
        }
        for i in docs.indices {
            guard let path = docs[i]["path"] as? String else { continue }
            do {
                docs[i]["disk"] = try FileIO.read(path).json
            } catch let error as FileIO.ReadError {
                docs[i]["diskError"] = error.message
                Log.write("session.file_unreadable", "\(path) \(error.message)")
            } catch {
                docs[i]["diskError"] = error.localizedDescription
            }
        }
        session["docs"] = docs
        // 読めた版を 1 つ前の控えとして残す（復元に失敗して上書きしてしまったときの保険）
        let prev = directory.appendingPathComponent("session.prev.json")
        try? FileManager.default.removeItem(at: prev)
        try? FileManager.default.copyItem(at: fileURL, to: prev)
        Log.write("session.loaded", "docs=\(docs.count) bytes=\(data.count)")
        return session
    }

    /// 書き込みは一時ファイルに書いてから置き換える（途中で落ちても壊れない）
    func save(_ session: Any, completion: (() -> Void)? = nil) {
        guard JSONSerialization.isValidJSONObject(session),
              let data = try? JSONSerialization.data(withJSONObject: session, options: [.sortedKeys]) else {
            Log.write("session.invalid")
            completion?()
            return
        }
        queue.async { [directory, fileURL] in
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try data.write(to: fileURL, options: .atomic)
            } catch {
                Log.write("session.write_failed", "\(error)")
            }
            // main キューでなく run loop に積む（終了を待つ modal の間も動くように。DocumentService を見よ）
            if let completion { RunLoop.main.perform(inModes: [.common], block: completion) }
        }
    }

    private func moveAsideBroken() {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let aside = directory.appendingPathComponent("session.broken-\(formatter.string(from: Date())).json")
        do {
            try FileManager.default.moveItem(at: fileURL, to: aside)
            Log.write("session.broken", "moved to \(aside.path)")
        } catch {
            Log.write("session.broken", "move failed: \(error)")
        }
    }
}
