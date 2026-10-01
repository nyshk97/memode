import AppKit
import ApplicationServices

/// 左 Shift のダブルタップを拾う。グローバル（他のアプリが前面のとき）とローカル（自分のパネルが
/// キーのとき）の両方を登録する。グローバルな監視はアクセシビリティの許可が無いと何も届かない
final class ShiftTapMonitor {
    private var detector = DoubleTapDetector()
    private var monitors: [Any] = []
    private var permissionTimer: Timer?
    private let onDoubleTap: () -> Void

    init(onDoubleTap: @escaping () -> Void) {
        self.onDoubleTap = onDoubleTap
    }

    var isTrusted: Bool { AXIsProcessTrusted() }

    /// 許可が無ければダイアログを出し、許可されるまで待ってから監視を始める
    func start() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if AXIsProcessTrustedWithOptions(options) {
            Log.write("accessibility.granted")
            install()
            return
        }
        Log.write("accessibility.not_granted", "waiting")
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] timer in
            guard AXIsProcessTrusted() else { return }
            timer.invalidate()
            self?.permissionTimer = nil
            Log.write("accessibility.granted")
            self?.install()
        }
    }

    private func install() {
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] in self?.feed($0) }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] in
            self?.feed($0)
            return $0
        }) {
            monitors.append(local)
        }
        Log.write("hotkey.monitor_started", "count=\(monitors.count)")
    }

    func feed(_ event: NSEvent) {
        feed(kind: event.type == .keyDown ? .keyDown : .flagsChanged,
             keyCode: event.keyCode, modifierFlags: event.modifierFlags.rawValue, timestamp: event.timestamp)
    }

    /// 監視から届いたイベントと同じ入口（dev 版の自走の検証からも呼ぶ）
    func feed(kind: ShiftTapMapping.Kind, keyCode: UInt16, modifierFlags: UInt, timestamp: TimeInterval) {
        let input = ShiftTapMapping.input(kind: kind, keyCode: keyCode, modifierFlags: modifierFlags, timestamp: timestamp)
        if detector.handle(input) {
            Log.write("hotkey.double_tap")
            onDoubleTap()
        }
    }
}
