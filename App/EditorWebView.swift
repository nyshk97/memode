import AppKit
import UniformTypeIdentifiers
import WebKit

/// .app の Resources/editor を `memode-editor://app/...` で配る。
/// `file://` だと Monaco の worker が動かないので、独自の URL スキームで読む
final class EditorSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "memode-editor"
    private let root: URL

    init(root: URL) {
        self.root = root.standardizedFileURL
    }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        var path = url.path
        if path.isEmpty || path == "/" { path = "/index.html" }
        let file = root.appendingPathComponent(String(path.dropFirst())).standardizedFileURL
        // Resources/editor の外は読ませない
        guard file.path.hasPrefix(root.path + "/"), let data = try? Data(contentsOf: file) else {
            Log.write("editor.resource_missing", path)
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        #if DEBUG
        Log.write("editor.serve", path)
        #endif
        let mime = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        let response = HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": mime, "Content-Length": String(data.count)])!
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}

/// Swift と JS の受け渡し。JS の準備ができる前に来た要求はためておき、ready が来てから流す
final class EditorBridge: NSObject, WKScriptMessageHandler {
    weak var webView: WKWebView?
    private(set) var isReady = false
    /// JS から回ってきたメニュー操作（Ctrl+Tab）
    var onAction: ((String) -> Void)?
    /// 掴んで動かせる場所（タブバーの空き。PopupPanel.dragRegions）
    var onDragRegions: (([CGRect]) -> Void)?
    /// それ以外の要求（保存・セッション等。DocumentService が受ける）
    var onMessage: ((String, [String: Any]) -> Void)?
    private var pending: [[String: Any]] = []
    private var readyWaiters: [() -> Void] = []

    func send(_ message: [String: Any]) {
        guard isReady else {
            pending.append(message)
            return
        }
        evaluate(message)
    }

    /// ready になったら（すでに ready なら即）呼ぶ
    func whenReady(_ body: @escaping () -> Void) {
        if isReady { body() } else { readyWaiters.append(body) }
    }

    /// エディタに文字を打てる状態か（debugState は中身を丸ごと作るので、常用版の経路では使わない）
    func editorFocused() async -> Bool {
        guard let webView else { return false }
        let result = try? await webView.callAsyncJavaScript(
            "return window.memode.editorFocused()", arguments: [:], contentWorld: .page)
        return result as? Bool == true
    }

    /// JS 側の状態を読む（dev 版の自走の検証用）
    func debugState() async -> [String: Any]? {
        guard let webView else { return nil }
        let result = try? await webView.callAsyncJavaScript(
            "return window.memode.debugState()", arguments: [:], contentWorld: .page)
        return result as? [String: Any]
    }

    private func evaluate(_ message: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: message),
              let json = String(data: data, encoding: .utf8) else { return }
        webView?.evaluateJavaScript("window.memode.receive(\(json))") { _, error in
            if let error { Log.write("bridge.send_failed", "\(error)") }
        }
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        switch type {
        case "ready":
            isReady = true
            Log.write("editor.ready", "pending=\(pending.count)")
            let queued = pending
            pending.removeAll()
            queued.forEach(evaluate)
            let waiters = readyWaiters
            readyWaiters.removeAll()
            waiters.forEach { $0() }
        case "action":
            if let action = body["action"] as? String { onAction?(action) }
        case "dragRegions":
            let rects = (body["rects"] as? [[String: Double]] ?? []).compactMap { r -> CGRect? in
                guard let x = r["x"], let y = r["y"], let w = r["width"], let h = r["height"] else { return nil }
                return CGRect(x: x, y: y, width: w, height: h)
            }
            onDragRegions?(rects)
        case "log":
            Log.write("js.\(body["event"] as? String ?? "?")", body["detail"] as? String ?? "")
        default:
            onMessage?(type, body)
        }
    }
}

/// Finder からファイルをドロップされたら、ページを移動させずにそのファイルをタブで開く
/// （WKWebView は既定でドロップされたファイルへページごと移動し、エディタが消える）。
/// エディタの中での文字のドラッグはファイルの URL を持たないので、そのまま WKWebView に任せる
final class EditorWebView: WKWebView {
    var onDropFiles: (([String]) -> Void)?

    private func fileURLs(_ info: NSDraggingInfo) -> [URL] {
        info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        fileURLs(sender).isEmpty ? super.draggingEntered(sender) : .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        fileURLs(sender).isEmpty ? super.draggingUpdated(sender) : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = fileURLs(sender)
        guard !urls.isEmpty else { return super.performDragOperation(sender) }
        Log.write("editor.drop_files", "count=\(urls.count)")
        onDropFiles?(urls.map(\.path))
        return true
    }
}

/// エディタのページ（memode-editor://）以外への移動はすべて止める（リンク・ドロップ等でエディタが消えないように）
final class EditorNavigationGuard: NSObject, WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if action.request.url?.scheme == EditorSchemeHandler.scheme {
            decisionHandler(.allow)
        } else {
            Log.write("editor.navigation_blocked", action.request.url?.absoluteString ?? "?")
            decisionHandler(.cancel)
        }
    }
}

enum EditorWebViewFactory {
    private static let navigationGuard = EditorNavigationGuard()

    static func make(bridge: EditorBridge) -> EditorWebView {
        let config = WKWebViewConfiguration()
        let root = Bundle.main.resourceURL!.appendingPathComponent("editor", isDirectory: true)
        config.setURLSchemeHandler(EditorSchemeHandler(root: root), forURLScheme: EditorSchemeHandler.scheme)
        config.userContentController.add(bridge, name: "memode")
        let webView = EditorWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = navigationGuard
        #if DEBUG
        webView.isInspectable = true
        #endif
        // 読み込み中の白いちらつきを避ける（背景は HTML 側の Canvas 色）
        webView.setValue(false, forKey: "drawsBackground")
        bridge.webView = webView
        webView.load(URLRequest(url: URL(string: "\(EditorSchemeHandler.scheme)://app/index.html")!))
        return webView
    }
}
