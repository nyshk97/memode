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

    var isVisible: Bool { panel.isVisible }
    /// 出す直前に前面にいたアプリ（activating のとき、ダブルタップで隠したらここへ戻す）
    private var previousApp: NSRunningApplication?
    /// フォーカスが外れて隠した時刻（メニューバーの「表示 / 隠す」を押したとき、その操作で
    /// フォーカスが外れて隠れた直後にまた出してしまわないように使う）
    private(set) var lastFocusLostHideAt: Date?
    /// 出したとき（開いているファイルが外で書き換わったかを確かめる）・隠したとき（セッションをすぐ保存する）
    var onShow: (() -> Void)?
    var onHide: (() -> Void)?
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
        panel.contentView = webView
        panel.delegate = self
        bridge.onDragRegions = { [weak self] rects in self?.panel.dragRegions = rects }
    }

    private static func makePanel(style: PanelStyle) -> PopupPanel {
        var mask: NSWindow.StyleMask = [.titled, .fullSizeContentView, .resizable]
        if style == .nonactivating { mask.insert(.nonactivatingPanel) }
        let panel = PopupPanel(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
                               styleMask: mask, backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
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
        panel.contentView = webView
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
        previousApp = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? previousApp : front
        // 出ているときは動かさない（別の画面にマウスがあっても、今の場所のまま前に出すだけ）
        if !panel.isVisible { applyFrame(frame(on: Self.mouseScreen())) }
        if style == .activating {
            // macOS 14 からの協調型のアクティベーションでは activate() だけだと断られることがある
            NSApp.activate(ignoringOtherApps: true)
        }
        panel.makeKeyAndOrderFront(nil)
        focusEditor()
        onShow?()
        Log.write("panel.show", "style=\(style.rawValue) frame=\(NSStringFromRect(panel.frame))")
    }

    func hide(reason: HideReason) {
        guard isVisible else { return }
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

    // MARK: - NSWindowDelegate

    func windowDidResignKey(_ notification: Notification) {
        // キーの移り先が決まるのを待ってから判断する
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isVisible, !self.panel.isKeyWindow else { return }
            let keyWindow = NSApp.keyWindow
            let hide = HideRules.shouldHideOnResignKey(
                keyWindowIsOurs: keyWindow != nil,
                hasAttachedSheet: self.panel.attachedSheet != nil,
                appIsModal: NSApp.modalWindow != nil)
            Log.write("panel.resign_key", "hide=\(hide) keyWindow=\(keyWindow.map { String(describing: type(of: $0)) } ?? "none")")
            if hide { self.hide(reason: .focusLost) }
        }
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
