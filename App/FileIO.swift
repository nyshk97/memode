import CryptoKit
import Foundation

/// ファイルの読み書き（ユニットテストする）。
/// - UTF-8 だけ扱う。読めないもの・NUL を含むもの（バイナリ）・大きすぎるものは開かない
/// - BOM は読んだときに外して覚えておき、書き戻すときに付け直す
/// - 改行コード（CRLF）は中身の文字列にそのまま残る（Monaco が保ったまま編集する）ので、ここでは触らない
enum FileIO {
    static let maxSize = 10 * 1024 * 1024
    private static let bomBytes: [UInt8] = [0xEF, 0xBB, 0xBF]

    /// 外で書き換わったかを比べるための目印
    struct Base: Equatable {
        var mtime: Double
        var size: Int
        var hash: String

        var json: [String: Any] { ["mtime": mtime, "size": size, "hash": hash] }

        init(mtime: Double, size: Int, hash: String) {
            self.mtime = mtime
            self.size = size
            self.hash = hash
        }

        init?(json: Any?) {
            guard let d = json as? [String: Any], let mtime = d["mtime"] as? Double,
                  let size = d["size"] as? Int, let hash = d["hash"] as? String else { return nil }
            self.init(mtime: mtime, size: size, hash: hash)
        }
    }

    struct Snapshot {
        var content: String
        var bom: Bool
        var base: Base

        var json: [String: Any] { ["content": content, "bom": bom, "base": base.json] }
    }

    enum ReadError: Error, Equatable {
        case notFound
        case tooLarge(Int)
        case binary
        case notUTF8
        case other(String)

        var message: String {
            switch self {
            case .notFound: return "ファイルが見つかりません"
            case .tooLarge(let size): return "大きすぎて開けません（\(size / 1024 / 1024)MB。上限は \(FileIO.maxSize / 1024 / 1024)MB）"
            case .binary: return "バイナリファイルなので開けません"
            case .notUTF8: return "UTF-8 として読めないので開けません（Shift_JIS などは未対応）"
            case .other(let s): return s
            }
        }
    }

    /// シンボリックリンクなら最後のリンク先まで（~/.zshrc → Dropbox の dotfiles 等）。
    /// attributesOfItem はリンク自身の大きさ・日付を返すので、読み書きと目印は必ずリンク先で行う。
    /// resolvingSymlinksInPath は /private/var を /var に戻すなど書き方を変えるので使わず、最後の要素だけたどる
    static func resolveLink(_ path: String) -> String {
        var current = path
        for _ in 0..<32 {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: current),
                  attrs[.type] as? FileAttributeType == .typeSymbolicLink,
                  let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: current) else { return current }
            current = dest.hasPrefix("/") ? dest : ((current as NSString).deletingLastPathComponent as NSString).appendingPathComponent(dest)
        }
        return current
    }

    static func read(_ path: String) throws -> Snapshot {
        let path = resolveLink(path)
        let url = URL(fileURLWithPath: path)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else { throw ReadError.notFound }
        let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
        if size > maxSize { throw ReadError.tooLarge(size) }
        let data: Data
        do { data = try Data(contentsOf: url) } catch { throw ReadError.other(error.localizedDescription) }
        if data.contains(0) { throw ReadError.binary }
        let hasBOM = data.starts(with: bomBytes)
        let body = hasBOM ? data.dropFirst(bomBytes.count) : data[...]
        guard let content = String(data: Data(body), encoding: .utf8) else { throw ReadError.notUTF8 }
        return Snapshot(content: content, bom: hasBOM, base: base(of: data, attrs: attrs))
    }

    /// 一時ファイルに書いてから置き換える（途中で落ちても元のファイルが壊れない）。
    /// 置き換えると別のファイルになるので、シンボリックリンクはリンク先に書き（リンクを普通のファイルに変えない）、
    /// 元の権限（スクリプトの +x 等）は書いた後に付け直す
    static func write(_ path: String, content: String, bom: Bool) throws -> Base {
        let target = resolveLink(path)
        let permissions = (try? FileManager.default.attributesOfItem(atPath: target))?[.posixPermissions]
        var data = Data(bom ? bomBytes : [])
        data.append(Data(content.utf8))
        try data.write(to: URL(fileURLWithPath: target), options: .atomic)
        if let permissions {
            try? FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: target)
        }
        let attrs = try FileManager.default.attributesOfItem(atPath: target)
        return base(of: data, attrs: attrs)
    }

    /// 外で書き換わったか。変わっていなければ nil、変わっていれば新しい中身（消えていれば .notFound を投げる）
    static func changedSince(_ path: String, base old: Base) throws -> Snapshot? {
        let path = resolveLink(path)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else { throw ReadError.notFound }
        let size = (attrs[.size] as? NSNumber)?.intValue ?? -1
        let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        if size == old.size && mtime == old.mtime { return nil }
        let snapshot = try read(path)
        return snapshot.base.hash == old.hash ? nil : snapshot
    }

    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func base(of data: Data, attrs: [FileAttributeKey: Any]) -> Base {
        Base(mtime: (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0,
             size: data.count, hash: hash(data))
    }
}
