// パネルの真後ろに色付きの絵（壁紙のグラデーション＋文字の入った白い板）を出し、画面の領域ごと撮って終わる。
// パネルの下地は NSVisualEffectView（後ろを透かしてぼかす）なので、screencapture -l でウィンドウだけ撮ると
// 後ろが合成されず灰色に写る。透け具合はこれで後ろを決めてから撮る（使い方は VERIFY.md）。
// 引数: <x> <y> <w> <h>（CG 座標 = 画面の左上原点） <出力.png> [busy（色の縞。読みやすさの限界を見る）]
import AppKit

let a = CommandLine.arguments
let x = Double(a[1])!, y = Double(a[2])!, w = Double(a[3])!, h = Double(a[4])!
let out = a[5]
let busy = a.count > 6 && a[6] == "busy"

final class Art: NSView {
    override func draw(_ r: NSRect) {
        if busy {
            let colors: [NSColor] = [.systemRed, .systemYellow, .systemGreen, .systemTeal, .systemBlue, .systemPurple, .systemPink]
            let stripe = 60.0
            for i in 0..<Int(bounds.width / stripe) + 1 {
                colors[i % colors.count].setFill()
                NSRect(x: Double(i) * stripe, y: 0, width: stripe, height: bounds.height).fill()
            }
        } else {
            NSGradient(colors: [NSColor(red: 1, green: 0.54, blue: 0.36, alpha: 1),
                                NSColor(red: 0.42, green: 0.36, blue: 1, alpha: 1),
                                NSColor(red: 0.12, green: 0.71, blue: 0.79, alpha: 1)])!
                .draw(in: bounds, angle: -30)
        }
        // 後ろにある別のアプリ（白い板に文字）
        let doc = NSRect(x: bounds.width * 0.05, y: bounds.height * 0.15, width: bounds.width * 0.55, height: bounds.height * 0.7)
        NSColor.white.setFill()
        NSBezierPath(roundedRect: doc, xRadius: 10, yRadius: 10).fill()
        let text = String(repeating: "ポップアップのエディタを作る。左 Shift を 2 回押すと出てくる。 ", count: 30)
        (text as NSString).draw(in: doc.insetBy(dx: 20, dy: 20),
                                withAttributes: [.font: NSFont.systemFont(ofSize: 18), .foregroundColor: NSColor.black])
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let screenH = NSScreen.screens[0].frame.height
let win = NSWindow(contentRect: NSRect(x: x - 60, y: screenH - y - h - 60, width: w + 120, height: h + 120),
                   styleMask: .borderless, backing: .buffered, defer: false)
win.contentView = Art()
win.level = .normal
win.orderFrontRegardless()
DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    p.arguments = ["-x", "-R\(Int(x)),\(Int(y)),\(Int(w)),\(Int(h))", out]
    try? p.run()
    p.waitUntilExit()
    exit(0)
}
app.run()
