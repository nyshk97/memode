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

    /// 小さいサイズの既定（画面が狭ければ画面に収まる大きさまで縮める）
    static let compactSize = CGSize(width: 720, height: 480)

    /// 小さいサイズのときの置き場所。キャレット（ウィンドウの左上からの位置。上から下向き）の行の下端が、
    /// anchor の少し上に来るように置く（マウスの矢印は先端から右下に伸びるので、打った文字が矢印に隠れない）。
    /// 画面からはみ出す分は内側に寄せる
    static func compactFrame(size: CGSize, caret: CGRect, anchor: CGPoint, visible: CGRect) -> CGRect {
        let width = min(size.width, visible.width)
        let height = min(size.height, visible.height)
        let top = anchor.y + caretGap + caret.maxY
        var x = anchor.x - caret.minX
        var y = top - height
        x = min(max(x, visible.minX), visible.maxX - width)
        y = min(max(y, visible.minY), visible.maxY - height)
        return rounded(CGRect(x: x, y: y, width: width, height: height))
    }

    /// キャレットの行の下端とマウスの矢印の先端の間
    static let caretGap: CGFloat = 4

    /// 縮めるときは、今キャレットが見えている場所に、縮めた後のキャレットが来るようにする（compactFrame の anchor に渡す点）
    static func anchor(caret: CGRect, frame: CGRect) -> CGPoint {
        CGPoint(x: frame.minX + caret.minX, y: frame.maxY - caret.maxY - caretGap)
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
/// `screens` は広げたときの位置と大きさで、中身は画面の左下からの位置（PanelFrameRules.relative）。
/// `compact` は小さいときの大きさだけ（位置は出すたびにマウスの位置から決める）
final class PanelFrameStore {
    let fileURL: URL
    private var frames: [String: CGRect]
    private var compactSizes: [String: CGSize] = [:]

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
        for (id, f) in json["compact"] as? [String: [String: Double]] ?? [:] {
            guard let w = f["width"], let h = f["height"], w > 0, h > 0 else { continue }
            compactSizes[id] = CGSize(width: w, height: h)
        }
    }

    func compactSize(for screenID: String) -> CGSize? {
        compactSizes[screenID]
    }

    func setCompactSize(_ size: CGSize, for screenID: String) {
        guard compactSizes[screenID] != size else { return }
        compactSizes[screenID] = size
        write()
    }

    func frame(for screenID: String) -> CGRect? {
        frames[screenID]
    }

    func set(_ frame: CGRect, for screenID: String) {
        guard frames[screenID] != frame else { return }
        frames[screenID] = frame
        write()
    }

    /// 広げたときの位置と大きさ・小さいときの大きさの両方を消す
    func remove(screenID: String) {
        let removedFrame = frames.removeValue(forKey: screenID) != nil
        let removedSize = compactSizes.removeValue(forKey: screenID) != nil
        guard removedFrame || removedSize else { return }
        write()
    }

    private func write() {
        let screens = frames.mapValues { ["x": $0.minX, "y": $0.minY, "width": $0.width, "height": $0.height] }
        let compact = compactSizes.mapValues { ["width": $0.width, "height": $0.height] }
        guard let data = try? JSONSerialization.data(withJSONObject: ["screens": screens, "compact": compact], options: [.prettyPrinted, .sortedKeys]) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}
