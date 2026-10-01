import CoreGraphics
import Foundation

/// ポップアップの位置とサイズの決まり（ユニットテストする）。座標は AppKit の画面座標（左下が原点）
enum PanelFrameRules {
    /// 何も覚えていない画面で出す大きさ: 中央に、幅 min(80%, 1400pt)・高さ min(80%, 900pt)（visibleFrame 基準）
    static func defaultFrame(visible: CGRect) -> CGRect {
        let width = min(visible.width * 0.8, 1400)
        let height = min(visible.height * 0.8, 900)
        return rounded(CGRect(x: visible.midX - width / 2, y: visible.midY - height / 2, width: width, height: height))
    }

    /// 覚えるときは画面の左下からの位置にする（画面の並びを変えると、画面の座標そのものが動くため）
    static func relative(_ frame: CGRect, screenFrame: CGRect) -> CGRect {
        frame.offsetBy(dx: -screenFrame.minX, dy: -screenFrame.minY)
    }

    /// 覚えた位置を今の画面に戻す。解像度・Dock・メニューバーが変わってはみ出すなら、
    /// 大きすぎる分は縮め、はみ出した分は内側に寄せる
    static func restore(_ saved: CGRect, screenFrame: CGRect, visible: CGRect) -> CGRect {
        var frame = rounded(saved.offsetBy(dx: screenFrame.minX, dy: screenFrame.minY))
        frame.size.width = min(frame.width, visible.width)
        frame.size.height = min(frame.height, visible.height)
        frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
        frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
        return frame
    }

    /// 端数を落とす（integral は外側に広げるので、大きさが 1pt 変わることがある）
    private static func rounded(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX.rounded(), y: r.minY.rounded(), width: r.width.rounded(), height: r.height.rounded())
    }
}

/// 画面ごとに覚えた位置とサイズ（`<データ>/window.json`。キーはディスプレイの UUID）。
/// 中身は画面の左下からの位置（PanelFrameRules.relative）
final class PanelFrameStore {
    let fileURL: URL
    private var frames: [String: CGRect]

    init(directory: URL) {
        fileURL = directory.appendingPathComponent("window.json")
        frames = [:]
        guard let data = try? Data(contentsOf: fileURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let screens = json["screens"] as? [String: [String: Double]] else { return }
        for (id, f) in screens {
            guard let x = f["x"], let y = f["y"], let w = f["width"], let h = f["height"], w > 0, h > 0 else { continue }
            frames[id] = CGRect(x: x, y: y, width: w, height: h)
        }
    }

    func frame(for screenID: String) -> CGRect? {
        frames[screenID]
    }

    func set(_ frame: CGRect, for screenID: String) {
        guard frames[screenID] != frame else { return }
        frames[screenID] = frame
        write()
    }

    func remove(screenID: String) {
        guard frames.removeValue(forKey: screenID) != nil else { return }
        write()
    }

    private func write() {
        let screens = frames.mapValues { ["x": $0.minX, "y": $0.minY, "width": $0.width, "height": $0.height] }
        guard let data = try? JSONSerialization.data(withJSONObject: ["screens": screens], options: [.prettyPrinted, .sortedKeys]) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}
