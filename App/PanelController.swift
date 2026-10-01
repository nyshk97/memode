import AppKit
import WebKit

final class PopupPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
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

    init(style: PanelStyle) {
        self.style = style
        bridge = EditorBridge()
        webView = EditorWebViewFactory.make(bridge: bridge)
        panel = Self.makePanel(style: style)
        super.init()
        panel.contentView = webView
        panel.delegate = self
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
        return panel
    }

    /// 方式を切り替える（dev 版のメニューから）。styleMask の nonactivatingPanel は
    /// 作った後に変えると効かないことがあるので、パネルごと作り直して WKWebView を移す
    func switchStyle(to newStyle: PanelStyle) {
        guard newStyle != style else { return }
        let wasVisible = isVisible
        panel.orderOut(nil)
        panel.contentView = nil
        style = newStyle
        panel = Self.makePanel(style: newStyle)
        panel.contentView = webView
        panel.delegate = self
        Log.write("panel.style_changed", newStyle.rawValue)
        if wasVisible { show() }
    }

    func toggle() {
        if isVisible { hide(reason: .toggle) } else { show() }
    }

    func show() {
        let front = NSWorkspace.shared.frontmostApplication
        previousApp = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? previousApp : front
        panel.setFrame(Self.frameForMouseScreen(), display: false)
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

    /// マウスがある画面の中央。幅 min(80%, 1400pt)・高さ min(80%, 900pt)（visibleFrame 基準）。
    /// NSScreen.main は常駐アプリだと当てにならないので、マウスの位置から画面を探す
    static func frameForMouseScreen() -> NSRect {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        let width = min(visible.width * 0.8, 1400)
        let height = min(visible.height * 0.8, 900)
        return NSRect(x: visible.midX - width / 2, y: visible.midY - height / 2, width: width, height: height).integral
    }
}
