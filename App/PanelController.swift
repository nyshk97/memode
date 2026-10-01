import AppKit
import WebKit

final class PopupPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    /// 掴んで動かせる場所（タブバーのタブの右の空き）。JS が送ってくる、ページの左上からの位置（CSS px）。
    /// mousedown を JS に回してから動かし始めると間に合わないので、場所を先にもらっておいてここで判定する
    var dragRegions: [CGRect] = []

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown, attachedSheet == nil, isDragRegion(event.locationInWindow) {
            performDrag(with: event)
            return
        }
        super.sendEvent(event)
    }

    func isDragRegion(_ locationInWindow: NSPoint) -> Bool {
        guard let view = contentView else { return false }
        var p = view.convert(locationInWindow, from: nil)
        if !view.isFlipped { p.y = view.bounds.height - p.y }
        return dragRegions.contains { $0.contains(p) }
    }
}

/// ポップアップの出し入れ。WKWebView はパネルを作り直しても同じものを使い回す（中身を保つため）
final class PanelController: NSObject, NSWindowDelegate {
    private(set) var panel: PopupPanel
    private(set) var style: PanelStyle
    let webView: EditorWebView
    let bridge: EditorBridge
    /// 後ろを透かしてぼかす下地。WKWebView はこの上に載せ、ページ側は半透明の色だけ塗る
    private let backdrop = PanelController.makeBackdrop()

    var isVisible: Bool { panel.isVisible }
    /// 出す直前に前面にいたアプリ（activating のとき、ダブルタップで隠したらここへ戻す）
    private(set) var previousApp: NSRunningApplication?
    /// フォーカスが外れて隠した時刻（メニューバーの「表示 / 隠す」を押したとき、その操作で
    /// フォーカスが外れて隠れた直後にまた出してしまわないように使う）
    private(set) var lastFocusLostHideAt: Date?
    /// 出したとき（開いているファイルが外で書き換わったかを確かめる）・隠したとき（セッションをすぐ保存する）
    var onShow: (() -> Void)?
    var onHide: (() -> Void)?
    /// mycast（クリップボード履歴を持つランチャー）か。dev 版の自走の検証で差し替える
    var isLauncher: (String?) -> Bool = LendRules.isLauncher
    /// mycast にキー入力を貸しているか
    var isLent: Bool { lendTimer != nil }
    /// 貸している間、mycast のパネルを見張る（他のアプリのウィンドウが閉じたことを知らせる通知は無い）
    private var lendTimer: Timer?
    /// mycast のパネルが画面から消えた時刻
    private var launcherGoneAt: Date?
    /// 画面ごとに覚えた位置とサイズ
    let frameStore: PanelFrameStore
    /// 最後にこちらで置いた位置と大きさ。これと違っていたら、人が動かした・大きさを変えたとみなして覚える
    private var appliedFrame: NSRect?
    private var pendingFrameSave: DispatchWorkItem?

    init(style: PanelStyle, frameStore: PanelFrameStore) {
        self.style = style
        self.frameStore = frameStore
        bridge = EditorBridge()
        webView = EditorWebViewFactory.make(bridge: bridge)
        panel = Self.makePanel(style: style)
        super.init()
        webView.frame = backdrop.bounds
        webView.autoresizingMask = [.width, .height]
        backdrop.addSubview(webView)
        panel.contentView = backdrop
        panel.delegate = self
        bridge.onDragRegions = { [weak self] rects in self?.panel.dragRegions = rects }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            self?.appDidActivate(note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)
        }
    }

    private static func makePanel(style: PanelStyle) -> PopupPanel {
        var mask: NSWindow.StyleMask = [.titled, .fullSizeContentView, .resizable]
        if style == .nonactivating { mask.insert(.nonactivatingPanel) }
        let panel = PopupPanel(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
                               styleMask: mask, backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        // 背景は backdrop（NSVisualEffectView）が描く
        panel.isOpaque = false
        panel.backgroundColor = .clear
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }
        panel.level = .floating
        // 全部の Space に出し、全画面アプリの上にも出す（.moveToActiveSpace と同時に指定すると例外）
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .utilityWindow
        panel.contentMinSize = NSSize(width: 480, height: 300)
        return panel
    }

    private static func makeBackdrop() -> NSVisualEffectView {
        let view = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 1000, height: 700))
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        // nonactivating のパネルはアプリがアクティブにならないので、既定（followsWindowActiveState）だと
        // 非アクティブの灰色の見た目になる
        view.state = .active
        return view
    }

    /// 方式を切り替える（dev 版のメニューから）。styleMask の nonactivatingPanel は
    /// 作った後に変えると効かないことがあるので、パネルごと作り直して WKWebView を移す
    func switchStyle(to newStyle: PanelStyle) {
        guard newStyle != style else { return }
        let wasVisible = isVisible
        let frame = panel.frame
        let regions = panel.dragRegions
        panel.orderOut(nil)
        panel.contentView = nil
        style = newStyle
        panel = Self.makePanel(style: newStyle)
        panel.contentView = backdrop
        panel.delegate = self
        panel.dragRegions = regions
        panel.setFrame(frame, display: false)
        Log.write("panel.style_changed", newStyle.rawValue)
        if wasVisible { show() }
    }

    func toggle() {
        if isVisible { hide(reason: .toggle) } else { show() }
    }

    func show() {
        let front = NSWorkspace.shared.frontmostApplication
        if LendRules.shouldRememberFront(isOwn: front?.processIdentifier == ProcessInfo.processInfo.processIdentifier,
                                         isLauncher: isLauncher(front?.bundleIdentifier)) {
            previousApp = front
        }
        // 出ているときは動かさない（別の画面にマウスがあっても、今の場所のまま前に出すだけ）
        let wasHidden = !panel.isVisible
        if wasHidden {
            applyFrame(frame(on: Self.mouseScreen()))
            panel.alphaValue = 0
        }
        if style == .activating {
            // macOS 14 からの協調型のアクティベーションでは activate() だけだと断られることがある
            NSApp.activate(ignoringOtherApps: true)
        }
        panel.makeKeyAndOrderFront(nil)
        if wasHidden {
            bridge.send(["type": "appear"])
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16
                panel.animator().alphaValue = 1
            }
        }
        focusEditor()
        onShow?()
        Log.write("panel.show", "style=\(style.rawValue) frame=\(NSStringFromRect(panel.frame))")
    }

    func hide(reason: HideReason) {
        guard isVisible else { return }
        if isLent { endLend(reason: reason.rawValue) }
        // 動かしてすぐ隠したときも覚える
        if let work = pendingFrameSave, !work.isCancelled {
            work.cancel()
            rememberFrame()
        }
        panel.orderOut(nil)
        if reason == .focusLost { lastFocusLostHideAt = Date() }
        var restored = "-"
        if HideRules.shouldRestorePreviousApp(reason: reason, style: style),
           let app = previousApp, !app.isTerminated {
            NSApp.yieldActivation(to: app)
            app.activate(options: [])
            restored = app.localizedName ?? "?"
        }
        Log.write("panel.hide", "reason=\(reason.rawValue) restored=\(restored)")
        onHide?()
    }

    func focusEditor() {
        panel.makeFirstResponder(webView)
        bridge.send(["type": "focus"])
    }

    // MARK: - mycast に貸す

    /// mycast から返ってきた（`memode://focus`・`memode://paste`）。key を取り直し、paste ならペーストボードの中身をエディタに貼る。
    /// 隠れていたら出すだけ（URL はブラウザのリンクからも叩けるので、勝手に中身を入れない）
    func takeBack(paste: Bool) {
        let wasVisible = isVisible
        // key にすると windowDidBecomeKey で抜けてしまうので、その前に理由を付けて抜けておく
        if isLent { endLend(reason: paste ? "paste" : "focus") }
        show()
        guard paste else { return }
        guard wasVisible else {
            Log.write("panel.paste_skipped", "hidden")
            return
        }
        Task { @MainActor in
            // show() は JS に focus を投げるだけなので、エディタにフォーカスが戻ってから貼る
            var focused = false
            for _ in 0..<20 {
                let editorFocused = await bridge.editorFocused()
                focused = panel.isKeyWindow && editorFocused
                if focused { break }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            // 待っている間に隠れた・key を取られたときは送らない（送っても届かない）
            guard isVisible, panel.isKeyWindow else {
                Log.write("panel.paste_skipped", "not_key focused=\(focused)")
                return
            }
            let sent = NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil)
            Log.write("panel.paste", "focused=\(focused) sent=\(sent)")
        }
    }

    /// パネルが key を失ったときに決める（隠す・貸す・待つ）
    private func decideOnResignKey(waited: Bool) {
        guard isVisible, !panel.isKeyWindow, !isLent else { return }
        let keyWindow = NSApp.keyWindow
        let decision = LendRules.onResignKey(
            keyWindowIsOurs: keyWindow != nil,
            hasAttachedSheet: panel.attachedSheet != nil,
            appIsModal: NSApp.modalWindow != nil,
            launcherPanelVisible: launcherPanelVisible(),
            front: front(NSWorkspace.shared.frontmostApplication),
            waited: waited)
        Log.write("panel.resign_key", "decision=\(decision.rawValue) keyWindow=\(keyWindow.map { String(describing: type(of: $0)) } ?? "none") front=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "-")")
        switch decision {
        case .keep:
            break
        case .hide:
            hide(reason: .focusLost)
        case .lend:
            startLend()
        case .wait:
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.decideOnResignKey(waited: true) }
        }
    }

    private func startLend() {
        launcherGoneAt = nil
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in self?.lendTick() }
        RunLoop.main.add(timer, forMode: .common)
        lendTimer = timer
        Log.write("panel.lend", "home=\(previousApp?.bundleIdentifier ?? "-")")
    }

    private func endLend(reason: String) {
        lendTimer?.invalidate()
        lendTimer = nil
        launcherGoneAt = nil
        Log.write("panel.lend_end", "reason=\(reason)")
    }

    private func lendTick() {
        guard isLent else { return }
        let result = LendRules.tick(launcherPanelVisible: launcherPanelVisible(), goneAt: launcherGoneAt, now: Date())
        launcherGoneAt = result.goneAt
        if result.hide {
            endLend(reason: "timeout")
            hide(reason: .focusLost)
        }
    }

    private func appDidActivate(_ app: NSRunningApplication?) {
        guard isLent, LendRules.shouldHideOnActivate(front(app)) else { return }
        endLend(reason: "other_app:\(app?.bundleIdentifier ?? "-")")
        hide(reason: .focusLost)
    }

    private func front(_ app: NSRunningApplication?) -> LendRules.Front {
        guard let app else { return .home }
        if app.processIdentifier == ProcessInfo.processInfo.processIdentifier { return .own }
        if isLauncher(app.bundleIdentifier) { return .launcher }
        if app.processIdentifier == previousApp?.processIdentifier { return .home }
        return .other
    }

    private func launcherPanelVisible() -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return false }
        var bundleIDs: [pid_t: String?] = [:]
        return list.contains { info in
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let bounds = (info[kCGWindowBounds as String] as? NSDictionary).flatMap({ CGRect(dictionaryRepresentation: $0) }) else { return false }
            let layer = info[kCGWindowLayer as String] as? Int ?? 0
            // レイヤーで外せるものは、アプリを引く前に外す
            guard layer == LendRules.floatingLayer else { return false }
            let id = bundleIDs[pid] ?? NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
            bundleIDs[pid] = id
            return LendRules.isLauncherPanel(ScreenWindow(bundleID: id, layer: layer, size: bounds.size), isLauncher: isLauncher)
        }
    }

    // MARK: - NSWindowDelegate

    func windowDidResignKey(_ notification: Notification) {
        // キーの移り先が決まるのを待ってから判断する
        DispatchQueue.main.async { [weak self] in self?.decideOnResignKey(waited: false) }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        // mycast が開いたままパネルをクリックした等。mycast からは何も返ってこない
        if isLent { endLend(reason: "key") }
    }

    func windowDidMove(_ notification: Notification) {
        rememberFrameSoon()
    }

    func windowDidResize(_ notification: Notification) {
        // 端を掴んで大きさを変えている間は、終わってから覚える
        if !panel.inLiveResize { rememberFrameSoon() }
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        rememberFrameSoon()
    }

    // MARK: - 位置と大きさ

    /// 出ている画面（隠れていればマウスのある画面）で覚えた位置と大きさを消し、既定の位置と大きさで出す
    func resetFrame() {
        let screen = (isVisible ? panel.screen : nil) ?? Self.mouseScreen()
        pendingFrameSave?.cancel()
        if let id = screen.memodeID { frameStore.remove(screenID: id) }
        Log.write("panel.frame_reset", "screen=\(screen.localizedName)")
        if isVisible {
            applyFrame(frame(on: screen))
        } else {
            show()
        }
    }

    /// その画面で覚えた位置と大きさ（覚えていなければ既定）
    func frame(on screen: NSScreen) -> NSRect {
        if let id = screen.memodeID, let saved = frameStore.frame(for: id) {
            return PanelFrameRules.restore(saved, screenFrame: screen.frame, visible: screen.visibleFrame)
        }
        return PanelFrameRules.defaultFrame(visible: screen.visibleFrame)
    }

    private func applyFrame(_ frame: NSRect) {
        appliedFrame = frame
        panel.setFrame(frame, display: panel.isVisible)
    }

    /// 動かしている間は何度も呼ばれるので、止まってから書く
    private func rememberFrameSoon() {
        pendingFrameSave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.rememberFrame() }
        pendingFrameSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func rememberFrame() {
        let frame = panel.frame
        // 出す前にこちらで置いたとき・置いたままのときは覚えない（既定の位置を覚えてしまうと、画面の解像度が変わっても追従しなくなる）
        guard panel.isVisible, frame != appliedFrame, let screen = panel.screen, let id = screen.memodeID else { return }
        appliedFrame = frame
        frameStore.set(PanelFrameRules.relative(frame, screenFrame: screen.frame), for: id)
        Log.write("panel.frame_saved", "screen=\(screen.localizedName) frame=\(NSStringFromRect(frame))")
    }

    /// NSScreen.main は常駐アプリだと当てにならないので、マウスの位置から画面を探す
    static func mouseScreen() -> NSScreen {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.screens[0]
    }
}

extension NSScreen {
    /// 画面を見分ける ID（ディスプレイの UUID。抜き差し・再起動しても変わらない）
    var memodeID: String? {
        guard let number = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }
}
