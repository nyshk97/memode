import AppKit
import UniformTypeIdentifiers

/// JS から来るファイルとセッションの要求を受ける（保存・閉じる前の確認・外での書き換えの確認・セッションの保存）
final class DocumentService {
    private let panel: PanelController
    private let store: SessionStore
    private var bridge: EditorBridge { panel.bridge }
    /// 今出している確認（dev 版の自走の検証で、ボタンを押すのに使う）
    private(set) var currentAlert: NSAlert?
    private(set) var currentSavePanel: NSSavePanel?
    /// 終了時に「最後のセッションを書き終えたら終了してよい」を待っている flush の番号
    private var pendingTerminateFlush: Int?
    private var nextFlushId = 1

    #if DEBUG
    /// 自走の検証で保存ダイアログ・ファイル選択を飛ばして使うパス（ダイアログ以外は本物の経路を通る）
    var savePathOverride: String?
    var openPathOverride: String?
    #endif

    /// 最近開いた・保存したファイル（新しい順。Cmd+P の候補）
    private(set) lazy var recentFiles: [String] = {
        guard let data = try? Data(contentsOf: recentURL),
              let list = try? JSONSerialization.jsonObject(with: data) as? [String] else { return [] }
        return list
    }()
    private var recentURL: URL { store.directory.appendingPathComponent("recent.json") }

    private func remember(_ path: String) {
        recentFiles.removeAll { $0 == path }
        recentFiles.insert(path, at: 0)
        if recentFiles.count > 100 { recentFiles.removeLast(recentFiles.count - 100) }
        if let data = try? JSONSerialization.data(withJSONObject: recentFiles, options: [.prettyPrinted]) {
            try? FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
            try? data.write(to: recentURL, options: .atomic)
        }
    }

    // MARK: - 登録フォルダ

    /// Cmd+P で中のファイルを探すフォルダ
    private(set) lazy var folders: [String] = {
        guard let data = try? Data(contentsOf: foldersURL),
              let list = try? JSONSerialization.jsonObject(with: data) as? [String] else { return [] }
        return list
    }()
    private var foldersURL: URL { store.directory.appendingPathComponent("folders.json") }
    private var folderCache: [String: (date: Date, files: [String])] = [:]
    private let indexQueue = DispatchQueue(label: "memode.folder-index")
    /// メニューの「登録フォルダ」を作り直す
    var onFoldersChanged: (() -> Void)?

    func registerFolder(_ path: String) {
        let path = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        guard !folders.contains(path) else { return }
        folders.append(path)
        saveFolders()
        Log.write("folder.registered", path)
        refreshIndex(force: false)
    }

    /// Cmd+P で探すホーム。dev 版は `--index-home <path>` で差し替えられる（自走の検証で本物のホームを走査しないように）
    static let indexHome: URL = {
        #if DEBUG
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--index-home"), i + 1 < args.count {
            return URL(fileURLWithPath: args[i + 1], isDirectory: true).resolvingSymlinksInPath()
        }
        #endif
        return FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath()
    }()
    /// 走査で返るパスはシンボリックリンクをたどったもの（/var → /private/var 等）なので、場所の目印もそろえる
    private var homeKey: String { Self.indexHome.path }

    /// 一覧を作る場所: ホーム全体と、登録フォルダ全部。ホームの中の登録フォルダも起点にする
    /// （ホームの一覧で除いている場所（~/Library の中・~/.config・build 等）を登録したときに出るように。重なりは送るときに除く）
    private var indexRoots: [String] {
        [homeKey] + folders.filter { $0 != homeKey }
    }

    /// 一覧が変わるたびに増やす。JS は前回受け取った版を持っていて、変わったときだけ一覧を受け取る
    private var indexVersion = 0
    private var sentIndexVersion = -1
    private static let indexTTL: TimeInterval = 300

    /// 一覧を裏で作っておく（起動時・登録したとき・Cmd+P で古くなっていたとき）
    func refreshIndex(force: Bool, completion: (() -> Void)? = nil) {
        let roots = indexRoots
        let home = homeKey
        let cache = folderCache
        indexQueue.async { [weak self] in
            FolderIndex.warmUp()
            var built: [String: (date: Date, files: [String])] = [:]
            for root in roots {
                if !force, let cached = cache[root], Date().timeIntervalSince(cached.date) < Self.indexTTL { continue }
                let started = Date()
                let files = root == home ? FolderIndex.homeFiles(home: URL(fileURLWithPath: home, isDirectory: true)) : FolderIndex.files(in: root)
                built[root] = (Date(), files)
                Log.write("folder.indexed", "\(root) files=\(files.count) ms=\(Int(Date().timeIntervalSince(started) * 1000))")
                // どこから何件入ったか（許可が無くて抜けた場所に気づけるように）
                var counts: [String: Int] = [:]
                for path in files where path.hasPrefix(root + "/") {
                    let rest = path.dropFirst(root.count + 1)
                    let top = rest.hasPrefix("Library/CloudStorage/") ? rest.split(separator: "/").prefix(3).joined(separator: "/") : String(rest.split(separator: "/").first ?? "")
                    counts[top, default: 0] += 1
                }
                Log.write("folder.indexed_by_dir", counts.sorted { $0.value > $1.value }.prefix(15).map { "\($0.key)=\($0.value)" }.joined(separator: " "))
            }
            DispatchQueue.main.async {
                guard let self else { return }
                if !built.isEmpty {
                    for (root, entry) in built where self.indexRoots.contains(root) { self.folderCache[root] = entry }
                    self.indexVersion += 1
                }
                completion?()
            }
        }
    }

    func unregisterFolder(_ path: String) {
        folders.removeAll { $0 == path }
        if folderCache.removeValue(forKey: path) != nil { indexVersion += 1 }
        saveFolders()
        Log.write("folder.unregistered", path)
    }

    private func saveFolders() {
        if let data = try? JSONSerialization.data(withJSONObject: folders, options: [.prettyPrinted]) {
            try? FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
            try? data.write(to: foldersURL, options: .atomic)
        }
        onFoldersChanged?()
    }

    /// フォルダを選んで登録する（メニューから）
    func chooseFolderToRegister() {
        if !panel.isVisible { panel.show() }
        let open = NSOpenPanel()
        open.canChooseFiles = false
        open.canChooseDirectories = true
        open.allowsMultipleSelection = true
        open.prompt = "登録"
        open.beginSheetModal(for: panel.panel) { [weak self] response in
            guard response == .OK else { return }
            open.urls.forEach { self?.registerFolder($0.path) }
        }
    }

    // MARK: - Cmd+P

    /// 候補（最近使ったファイル → ホームと登録フォルダの中）を JS に渡す。一覧は作っておいたものをすぐ使い、
    /// 5 分より古ければ裏で作り直す（次の Cmd+P から新しいファイルが出る）。まだ一覧が無い場所だけは作るのを待つ
    func quickOpen() {
        if !panel.isVisible { panel.show() }
        let roots = indexRoots
        if roots.contains(where: { folderCache[$0] == nil }) {
            refreshIndex(force: false) { [weak self] in self?.sendQuickOpen() }
            return
        }
        sendQuickOpen()
        if roots.contains(where: { Date().timeIntervalSince(folderCache[$0]!.date) >= Self.indexTTL }) {
            refreshIndex(force: false)
        }
    }

    private func sendQuickOpen() {
        let recents = recentFiles.filter { FileManager.default.fileExists(atPath: $0) }
        var msg: [String: Any] = ["type": "quickOpen", "version": indexVersion, "home": homeKey, "recents": recents]
        if sentIndexVersion != indexVersion {
            // 一覧はパスだけ送る（見出しと場所は JS 側で作る）。変わったときだけ
            var seen = Set<String>()
            msg["index"] = indexRoots.flatMap { folderCache[$0]?.files ?? [] }.filter { seen.insert($0).inserted }
            sentIndexVersion = indexVersion
        }
        Log.write("quick_open.send", "version=\(indexVersion) recents=\(recents.count) index=\((msg["index"] as? [String])?.count ?? -1)")
        bridge.send(msg)
    }

    // MARK: - memode://open?path=...

    /// `memode <path>` コマンド・URL から。ファイルなら開く、無いパスなら新しいファイルとして開く（保存したときに作る）、
    /// ディレクトリなら確認してから登録フォルダに入れて Cmd+P を出す（URL はブラウザのリンクからも叩けるので黙って登録しない）
    func openFromURL(_ url: URL) {
        let host = url.host ?? ""
        if host == "show" || host.isEmpty {
            if !panel.isVisible { panel.show() }
            return
        }
        // mycast（クリップボード履歴）が閉じたあと、キー入力を返しに来る
        if host == "focus" || host == "paste" {
            panel.takeBack(paste: host == "paste")
            return
        }
        guard host == "open",
              let raw = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "path" })?.value,
              raw.hasPrefix("/") else {
            Log.write("url.ignored", url.absoluteString)
            if !panel.isVisible { panel.show() }
            return
        }
        let path = (raw as NSString).standardizingPath
        var isDir: ObjCBool = false
        if !FileManager.default.fileExists(atPath: path, isDirectory: &isDir) {
            Log.write("file.open_new", path)
            if !panel.isVisible { panel.show() }
            bridge.send(["type": "openFile", "path": path, "disk": ["content": "", "bom": false], "isNew": true])
        } else if isDir.boolValue {
            if folders.contains(path) {
                quickOpen()
                return
            }
            showAlert(message: "「\((path as NSString).lastPathComponent)」を登録フォルダに入れますか？",
                      info: "\(path)\n登録したフォルダの中のファイルは Cmd+P で探せます。",
                      buttons: ["登録", "キャンセル"]) { [weak self] index in
                guard index == 0 else { return }
                self?.registerFolder(path)
                self?.quickOpen()
            }
        } else {
            open(paths: [path])
        }
    }

    // MARK: - 開く

    /// ファイルを読んでタブで開く（Cmd+O・Cmd+P・memode コマンドから）。開けないものは理由を出す
    func open(paths: [String]) {
        if !panel.isVisible { panel.show() }
        var failures: [String] = []
        for path in paths {
            do {
                let snapshot = try FileIO.read(path)
                Log.write("file.opened", "\(path) bytes=\(snapshot.base.size)")
                remember(path)
                bridge.send(["type": "openFile", "path": path, "disk": snapshot.json])
            } catch let error as FileIO.ReadError {
                Log.write("file.open_failed", "\(path) \(error.message)")
                failures.append("\((path as NSString).lastPathComponent): \(error.message)")
            } catch {
                failures.append("\((path as NSString).lastPathComponent): \(error.localizedDescription)")
            }
        }
        if !failures.isEmpty {
            showError("開けませんでした", failures.joined(separator: "\n"))
        }
    }

    init(panel: PanelController, store: SessionStore) {
        self.panel = panel
        self.store = store
    }

    /// 起動時: 前回のセッションを読み、JS の準備ができたら渡す
    func restore() {
        // 前回のセッションが無くても送る（JS はこれを受けるまでセッションを書かない。
        // 受ける前に書くと、起動直後の空の状態で前回のセッションを上書きしてしまうため）
        bridge.send(["type": "restore", "session": store.load() ?? NSNull()])
    }

    func handle(_ type: String, _ body: [String: Any]) {
        switch type {
        case "session":
            if let session = body["session"] {
                let flushId = body["flushId"] as? Int
                store.save(session) { [weak self] in
                    if let flushId, flushId == self?.pendingTerminateFlush { self?.finishTerminate(reason: "flushed") }
                }
            }
        case "sessionSkipped":
            // 前回のセッションを受け取る前に終了した（書くものが無い）
            if let flushId = body["flushId"] as? Int, flushId == pendingTerminateFlush { finishTerminate(reason: "skipped") }
        case "save":
            save(body)
        case "confirmClose":
            confirmClose(body)
        case "fileStates":
            checkFiles(body["files"] as? [[String: Any]] ?? [])
        case "askConflict":
            askConflict(body)
        case "quickOpenResend":
            // JS が一覧を持っていなかった（エディタ部分が読み直された等）
            sentIndexVersion = -1
            sendQuickOpen()
        case "openPaths":
            open(paths: body["paths"] as? [String] ?? [])
        default:
            Log.write("bridge.unknown_message", type)
        }
    }

    // MARK: - セッション

    /// 隠したときなど: JS に今の状態をすぐ送らせる
    func flushSession() {
        guard bridge.isReady else { return }
        bridge.send(["type": "flushSession"])
    }

    /// 終了時: JS から最後のセッションが届いて書き終わるまで待つ（数秒で諦める）
    func terminateRequested() -> NSApplication.TerminateReply {
        guard bridge.isReady else { return .terminateNow }
        let flushId = nextFlushId
        nextFlushId += 1
        pendingTerminateFlush = flushId
        bridge.send(["type": "flushSession", "flushId": flushId])
        // 終了を待つ間、AppKit は run loop を modal のモードで回す。終了が main キューのジョブの中から
        // 呼ばれていると、main キューに積んだものはその間ずっと動かない（自走の検証で実際に止まった）。
        // タイムアウトは run loop のタイマーにして、どこから終了を呼ばれても必ず終わるようにする
        let timer = Timer(timeInterval: 3, repeats: false) { [weak self] _ in
            if self?.pendingTerminateFlush == flushId {
                Log.write("session.flush_timeout", "最後にディスクへ書いたセッションのまま終了する")
                self?.finishTerminate(reason: "timeout")
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        return .terminateLater
    }

    private func finishTerminate(reason: String) {
        guard pendingTerminateFlush != nil else { return }
        pendingTerminateFlush = nil
        Log.write("app.terminate", reason)
        NSApp.reply(toApplicationShouldTerminate: true)
    }

    // MARK: - 保存

    private func save(_ body: [String: Any]) {
        guard let docId = body["docId"] as? Int, let content = body["content"] as? String else { return }
        let bom = body["bom"] as? Bool ?? false
        let version = body["version"] as? Int ?? 0
        let write = { [weak self] (path: String) in
            do {
                let base = try FileIO.write(path, content: content, bom: bom)
                Log.write("file.saved", "\(path) bytes=\(base.size)")
                self?.remember(path)
                self?.bridge.send(["type": "saved", "docId": docId, "path": path, "version": version, "bom": bom, "base": base.json])
            } catch {
                Log.write("file.save_failed", "\(path) \(error)")
                self?.bridge.send(["type": "saveFailed", "docId": docId])
                self?.showError("保存できませんでした", "\(path)\n\(error.localizedDescription)")
            }
        }
        if let path = body["path"] as? String {
            write(path)
            return
        }
        #if DEBUG
        if let override = savePathOverride {
            savePathOverride = nil
            write(override)
            return
        }
        #endif
        let savePanel = NSSavePanel()
        savePanel.nameFieldStringValue = body["suggestedName"] as? String ?? "scratch.txt"
        savePanel.canCreateDirectories = true
        savePanel.allowsOtherFileTypes = true
        currentSavePanel = savePanel
        savePanel.beginSheetModal(for: panel.panel) { [weak self] response in
            self?.currentSavePanel = nil
            guard response == .OK, let url = savePanel.url else {
                self?.bridge.send(["type": "saveCancelled", "docId": docId])
                return
            }
            write(url.path)
        }
    }

    // MARK: - 確認

    /// 保存済みファイルに未保存の変更があるタブを閉じるとき
    private func confirmClose(_ body: [String: Any]) {
        guard let docId = body["docId"] as? Int else { return }
        let name = body["name"] as? String ?? ""
        showAlert(message: "「\(name)」の変更を保存しますか？",
                  info: "保存しないと、変更は失われます。",
                  buttons: ["保存", "保存しない", "キャンセル"]) { [weak self] index in
            let decision = ["save", "discard", "cancel"][index]
            Log.write("file.close_decision", "\(name) \(decision)")
            self?.bridge.send(["type": "closeDecision", "docId": docId, "decision": decision])
        }
    }

    /// 開いているファイルが外で書き換わったか確かめる（ポップアップを出したときに JS が一覧を送ってくる）
    private func checkFiles(_ files: [[String: Any]]) {
        for file in files {
            guard let docId = file["docId"] as? Int, let path = file["path"] as? String else { continue }
            guard let base = FileIO.Base(json: file["base"]) else { continue }
            do {
                if let snapshot = try FileIO.changedSince(path, base: base) {
                    Log.write("file.changed_on_disk", path)
                    bridge.send(["type": "diskChanged", "docId": docId, "disk": snapshot.json])
                }
            } catch FileIO.ReadError.notFound {
                Log.write("file.missing", path)
                bridge.send(["type": "diskChanged", "docId": docId, "disk": NSNull()])
            } catch {
                Log.write("file.check_failed", "\(path) \(error)")
            }
        }
    }

    /// 未保存の変更があるファイルが外で書き換わったとき
    private func askConflict(_ body: [String: Any]) {
        guard let docId = body["docId"] as? Int else { return }
        let name = body["name"] as? String ?? ""
        showAlert(message: "「\(name)」がほかのアプリで変更されました",
                  info: "ファイルの内容を読み込むと、ここでの未保存の変更は失われます。",
                  buttons: ["ファイルの内容を読み込む", "自分の変更を残す"]) { [weak self] index in
            let decision = index == 0 ? "reload" : "keep"
            Log.write("file.conflict_decision", "\(name) \(decision)")
            self?.bridge.send(["type": "conflictDecision", "docId": docId, "decision": decision])
        }
    }

    private func showAlert(message: String, info: String, buttons: [String], completion: @escaping (Int) -> Void) {
        if !panel.isVisible { panel.show() }
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = info
        buttons.forEach { alert.addButton(withTitle: $0) }
        currentAlert = alert
        alert.beginSheetModal(for: panel.panel) { [weak self] response in
            self?.currentAlert = nil
            completion(response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue)
            self?.panel.focusEditor()
        }
    }

    private func showError(_ message: String, _ info: String) {
        showAlert(message: message, info: info, buttons: ["OK"]) { _ in }
    }
}
