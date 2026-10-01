import AppKit
import ApplicationServices
#if !DEBUG
import Sparkle
#endif

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private(set) var panelController: PanelController!
    private(set) var shiftTapMonitor: ShiftTapMonitor!
    private(set) var documents: DocumentService!
    private var statusItem: NSStatusItem!
    #if !DEBUG
    /// アプリ内アップデート（dev 版では動かさない。feed も Release にしか無い）。delegate に self を渡すので lazy にして、
    /// applicationDidFinishLaunching で作る
    private lazy var updaterController = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)

    @objc private func checkForUpdates(_ sender: Any?) {
        NSApp.activate()
        updaterController.checkForUpdates(sender)
    }
    #endif

    /// 見つかった新しい版（ステータスバーに「vX.Y.Z に更新」と出す）
    private var availableUpdate: String?

    /// 自走の検証（dev 版）で、メニューの操作が届いたかを数える
    private(set) var menuActionLog: [String] = []

    /// パネルと DocumentService は will の時点で作る。起動していない状態で `memode <path>` を叩くと、
    /// URL（application(_:open:)）は will と did の間に届くので、did で作ると捨ててしまう
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        terminateIfAlreadyRunning()
        Log.write("app.launch", "version=\(AppInfo.version) pid=\(ProcessInfo.processInfo.processIdentifier) dev=\(AppInfo.isDev)")

        NSApp.mainMenu = MainMenu.build(target: self, action: #selector(menuAction(_:)))
        panelController = PanelController(style: PanelStyle.current)
        panelController.bridge.onAction = { [weak self] raw in
            guard let action = MainMenu.Action(rawValue: raw) else { return }
            self?.perform(action, name: raw)
        }
        if AppInfo.dataDirOverride == nil {
            let result = AppInfo.migrateLegacyData(from: AppInfo.legacyDataDirectory, to: AppInfo.dataDirectory)
            if result != .nothingToMove {
                Log.write("app.data_migrate", "\(result) \(AppInfo.legacyDataDirectory.path) -> \(AppInfo.dataDirectory.path)")
            }
        }
        documents = DocumentService(panel: panelController, store: SessionStore(directory: AppInfo.dataDirectory))
        panelController.bridge.onMessage = { [weak self] type, body in self?.documents.handle(type, body) }
        panelController.onShow = { [weak self] in self?.panelController.bridge.send(["type": "checkFiles"]) }
        panelController.onHide = { [weak self] in self?.documents.flushSession() }
        panelController.webView.onDropFiles = { [weak self] paths in self?.documents.open(paths: paths) }
        documents.onFoldersChanged = { [weak self] in self?.rebuildStatusMenu() }
        documents.restore()
        documents.refreshIndex(force: true)
        sendAppInfo()
        Log.write("app.data_dir", AppInfo.dataDirectory.path)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if !DEBUG
        _ = updaterController
        #endif
        LoginItem.enableOnFirstLaunchIfNeeded()
        setUpStatusItem()
        shiftTapMonitor = ShiftTapMonitor { [weak self] in self?.panelController.toggle() }
        shiftTapMonitor.start()

        #if DEBUG
        DevHooks.run(app: self)
        #endif
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        documents?.terminateRequested() ?? .terminateNow
    }

    /// `memode://`（memode コマンド）と、Finder のダブルクリック・「このアプリケーションで開く」で届く file:// の両方がここに来る
    func application(_ application: NSApplication, open urls: [URL]) {
        let files = urls.filter(\.isFileURL)
        if !files.isEmpty {
            Log.write("file.open_from_finder", files.map(\.path).joined(separator: " "))
            documents?.open(paths: files.map(\.path))
        }
        for url in urls where !url.isFileURL {
            Log.write("url.open", url.absoluteString)
            documents?.openFromURL(url)
        }
    }

    // MARK: - メニュー

    @objc func menuAction(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let action = MainMenu.Action(rawValue: raw) else { return }
        perform(action, name: action == .selectTab ? "\(raw):\(sender.tag)" : raw, index: sender.tag)
    }

    private func perform(_ action: MainMenu.Action, name: String, index: Int = 0) {
        menuActionLog.append(name)
        Log.write("menu.\(name)")
        switch action {
        case .open:
            showOpenPanel()
        case .newTab, .closeTab, .selectTab, .nextTab, .previousTab, .toggleSplit, .chooseLanguage, .save, .saveAs:
            // タブと分割はエディタ（JS）側が持っている
            if !panelController.isVisible { panelController.show() }
            panelController.bridge.send(["type": "command", "name": action.rawValue, "index": index])
        case .quickOpen:
            documents.quickOpen()
        case .registerFolder:
            documents.chooseFolderToRegister()
        case .checkForUpdates:
            panelController.hide(reason: .checkForUpdates)
            #if !DEBUG
            checkForUpdates(nil)
            #endif
        }
    }

    /// ステータスバーの版の表示（JS の main.ts）に、今の版と見つかった新しい版を渡す
    private func sendAppInfo() {
        panelController.bridge.send([
            "type": "appInfo", "version": AppInfo.version, "dev": AppInfo.isDev,
            "update": availableUpdate ?? NSNull(),
        ])
    }

    /// Phase 2 ではパネルの前後関係を確かめるために出すだけ（開く処理は Phase 6）
    private(set) var currentOpenPanel: NSOpenPanel?

    private func showOpenPanel() {
        #if DEBUG
        if let override = documents.openPathOverride {
            documents.openPathOverride = nil
            documents.open(paths: [override])
            return
        }
        #endif
        let open = NSOpenPanel()
        open.canChooseDirectories = false
        open.allowsMultipleSelection = true
        if let last = UserDefaults.standard.string(forKey: "lastOpenDirectory") {
            open.directoryURL = URL(fileURLWithPath: last, isDirectory: true)
        }
        currentOpenPanel = open
        // ポップアップは .floating なので、普通のウィンドウとして出すと後ろに隠れる。シートで付ける
        open.beginSheetModal(for: panelController.panel) { [weak self] response in
            self?.currentOpenPanel = nil
            guard response == .OK, !open.urls.isEmpty else {
                Log.write("open_panel.closed", "cancel")
                return
            }
            UserDefaults.standard.set(open.urls[0].deletingLastPathComponent().path, forKey: "lastOpenDirectory")
            self?.documents.open(paths: open.urls.map(\.path))
        }
    }

    @objc func showAbout(_ sender: Any?) {
        NSApp.activate()
        // 同じ数字が「0.1.0 (0.1.0)」と 2 回出ないようにする
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationVersion: "Version \(AppInfo.version)",
            .version: "",
        ])
    }

    @objc private func togglePanel(_ sender: Any?) {
        // メニューバーを押した操作でフォーカスが外れて隠れた直後なら、出し直さない（隠すつもりで押している）
        if !panelController.isVisible, let at = panelController.lastFocusLostHideAt, Date().timeIntervalSince(at) < 0.5 {
            return
        }
        panelController.toggle()
    }

    @objc private func selectPanelStyle(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let style = PanelStyle(rawValue: raw) else { return }
        PanelStyle.current = style
        panelController.switchStyle(to: style)
        rebuildStatusMenu()
    }

    @objc private func registerFolderFromMenu(_ sender: Any?) {
        documents.chooseFolderToRegister()
    }

    @objc private func unregisterFolder(_ sender: NSMenuItem) {
        guard let folder = sender.representedObject as? String else { return }
        documents.unregisterFolder(folder)
    }

    @objc private func openDataFolder(_ sender: Any?) {
        try? FileManager.default.createDirectory(at: AppInfo.dataDirectory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(AppInfo.dataDirectory)
    }

    @objc private func toggleLoginItem(_ sender: Any?) {
        switch LoginItem.state {
        case .enabled: LoginItem.setEnabled(false)
        case .disabled: LoginItem.setEnabled(true)
        case .requiresApproval: LoginItem.openSystemSettings()
        }
    }

    /// 開くたびに今の状態に合わせる（システム設定の側で切り替えられることがある）
    private func updateLoginItemMenu(_ item: NSMenuItem) {
        let state = LoginItem.state
        item.title = state == .requiresApproval ? "ログイン時に起動（システム設定で許可が必要）" : "ログイン時に起動"
        item.state = state == .enabled ? .on : .off
    }

    @objc private func openAccessibilitySettings(_ sender: Any?) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    // MARK: - メニューバー

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "square.and.pencil", accessibilityDescription: "Memode")
            if AppInfo.isDev {
                button.imagePosition = .imageLeading
                button.title = "DEV"
            }
        }
        rebuildStatusMenu()
    }

    private func rebuildStatusMenu() {
        let menu = NSMenu()
        // 更新が当たったかをすぐ確かめられるよう、バージョンを一番上に出す
        let header = NSMenuItem(title: "Memode\(AppInfo.isDev ? "-dev" : "") v\(AppInfo.version)", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())
        let toggle = NSMenuItem(title: "表示 / 隠す（左 Shift を 2 回）", action: #selector(togglePanel(_:)), keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)
        menu.addItem(.separator())
        let register = NSMenuItem(title: "フォルダを登録…", action: #selector(registerFolderFromMenu(_:)), keyEquivalent: "")
        register.target = self
        menu.addItem(register)
        let folderMenu = NSMenu()
        for folder in documents.folders {
            let f = NSMenuItem(title: (folder as NSString).abbreviatingWithTildeInPath, action: #selector(unregisterFolder(_:)), keyEquivalent: "")
            f.target = self
            f.representedObject = folder
            f.toolTip = "クリックで登録を解除"
            folderMenu.addItem(f)
        }
        if documents.folders.isEmpty {
            folderMenu.addItem(withTitle: "（なし）", action: nil, keyEquivalent: "").isEnabled = false
        } else {
            folderMenu.addItem(.separator())
            folderMenu.addItem(withTitle: "クリックすると登録を解除する", action: nil, keyEquivalent: "").isEnabled = false
        }
        let folders = NSMenuItem(title: "登録フォルダ（\(documents.folders.count)）", action: nil, keyEquivalent: "")
        folders.submenu = folderMenu
        menu.addItem(folders)
        let dataFolder = NSMenuItem(title: "データのフォルダを開く", action: #selector(openDataFolder(_:)), keyEquivalent: "")
        dataFolder.target = self
        menu.addItem(dataFolder)
        let loginItem = NSMenuItem(title: "ログイン時に起動", action: #selector(toggleLoginItem(_:)), keyEquivalent: "")
        loginItem.target = self
        updateLoginItemMenu(loginItem)
        menu.addItem(loginItem)
        if !AXIsProcessTrusted() {
            let warn = NSMenuItem(title: "⚠︎ アクセシビリティの許可が必要（左 Shift が効かない）", action: #selector(openAccessibilitySettings(_:)), keyEquivalent: "")
            warn.target = self
            menu.addItem(warn)
        }

        #if DEBUG
        menu.addItem(.separator())
        let styleHeader = NSMenuItem(title: "パネルの方式（dev）", action: nil, keyEquivalent: "")
        styleHeader.isEnabled = false
        menu.addItem(styleHeader)
        for style in PanelStyle.allCases {
            let item = NSMenuItem(title: style.rawValue, action: #selector(selectPanelStyle(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = style.rawValue
            item.state = panelController.style == style ? .on : .off
            menu.addItem(item)
        }
        #endif

        menu.addItem(.separator())
        let about = NSMenuItem(title: "Memode について", action: #selector(showAbout(_:)), keyEquivalent: "")
        about.target = self
        menu.addItem(about)
        #if !DEBUG
        let update = NSMenuItem(title: "アップデートを確認…", action: #selector(checkForUpdates(_:)), keyEquivalent: "")
        update.target = self
        menu.addItem(update)
        #endif
        menu.addItem(NSMenuItem(title: "終了", action: #selector(NSApplication.terminate(_:)), keyEquivalent: ""))
        menu.delegate = self
        statusItem.menu = menu
    }

    /// 同じアプリが 2 つ動くと同じデータを書き合って壊すので、後から起動した方を終わらせる
    private func terminateIfAlreadyRunning() {
        guard let id = Bundle.main.bundleIdentifier else { return }
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        if let other = others.first {
            Log.write("app.already_running", "pid=\(other.processIdentifier)")
            NSApp.terminate(nil)
        }
    }
}

extension AppDelegate {
    /// 開くたびに作り直す（アクセシビリティの許可の警告を今の状態に合わせる）
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === statusItem.menu else { return }
        if let item = menu.items.first(where: { $0.action == #selector(toggleLoginItem(_:)) }) {
            updateLoginItemMenu(item)
        }
        guard AXIsProcessTrusted() else { return }
        if let i = menu.items.firstIndex(where: { $0.action == #selector(openAccessibilitySettings(_:)) }) {
            menu.removeItem(at: i)
        }
    }
}

#if !DEBUG
extension AppDelegate: SPUUpdaterDelegate {
    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        availableUpdate = item.displayVersionString
        Log.write("update.found", item.displayVersionString)
        sendAppInfo()
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        guard availableUpdate != nil else { return }
        availableUpdate = nil
        sendAppInfo()
    }
}
#endif
