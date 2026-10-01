// アプリアイコン（常用版と dev 版）を App/Assets.xcassets に書き出す。
//   swift scripts/make-icon.swift
// macOS 26 からはシステムが角丸・影を付けるので、角まで塗った正方形（フルブリード）で描く。
// dev 版は右下に「DEV」の帯を付ける（Dock・⌘Tab で常用版と見分けるため）。
// 生成物の PNG はコミットする（毎ビルドでは作らない）

import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "App/Assets.xcassets")
let sizes: [(points: Int, scale: Int)] = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]

func render(dev: Bool) -> NSBitmapImageRep {
    let canvas: CGFloat = 1024
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(canvas), pixelsHigh: Int(canvas),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let rect = NSRect(x: 0, y: 0, width: canvas, height: canvas)

    // 背景: 深い藍から青紫へ（上が明るい）
    NSGradient(colors: [NSColor(srgbRed: 0.11, green: 0.13, blue: 0.33, alpha: 1),
                        NSColor(srgbRed: 0.27, green: 0.33, blue: 0.85, alpha: 1)])!
        .draw(in: rect, angle: 90)

    // 中央: メモとペン（メニューバーのアイコンと同じ記号）
    let config = NSImage.SymbolConfiguration(pointSize: 520, weight: .medium)
        .applying(.init(paletteColors: [.white]))
    if let symbol = NSImage(systemSymbolName: "square.and.pencil", accessibilityDescription: nil)?
        .withSymbolConfiguration(config) {
        let s = symbol.size
        symbol.draw(in: NSRect(x: (canvas - s.width) / 2 + 20, y: (canvas - s.height) / 2 - 10, width: s.width, height: s.height))
    }

    if dev {
        // 右下の角を斜めに横切るオレンジの帯と「DEV」
        let ctx = NSGraphicsContext.current!.cgContext
        ctx.saveGState()
        ctx.translateBy(x: canvas * 0.74, y: canvas * 0.26)
        ctx.rotate(by: .pi / 4)
        let band = NSRect(x: -700, y: -95, width: 1400, height: 190)
        NSColor(srgbRed: 1.0, green: 0.55, blue: 0.1, alpha: 1).setFill()
        band.fill()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 130, weight: .heavy),
            .foregroundColor: NSColor.white,
            .kern: 12,
        ]
        let text = NSAttributedString(string: "DEV", attributes: attrs)
        let line = CTLineCreateWithAttributedString(text)
        let ink = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        ctx.textPosition = CGPoint(x: -ink.midX, y: -ink.midY)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func scaled(_ rep: NSBitmapImageRep, to pixels: Int) -> Data {
    let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
    NSGraphicsContext.current!.imageInterpolation = .high
    rep.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    return out.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
try fm.createDirectory(at: root, withIntermediateDirectories: true)
try Data(#"{"info":{"author":"xcode","version":1}}"#.utf8).write(to: root.appendingPathComponent("Contents.json"))

for (name, dev) in [("AppIcon", false), ("AppIconDev", true)] {
    let dir = root.appendingPathComponent("\(name).appiconset")
    try? fm.removeItem(at: dir)
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    let master = render(dev: dev)
    var images: [[String: String]] = []
    for (points, scale) in sizes {
        let file = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try scaled(master, to: points * scale).write(to: dir.appendingPathComponent(file))
        images.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": file])
    }
    let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
    try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
        .write(to: dir.appendingPathComponent("Contents.json"))
    print("\(name): \(dir.path)")
}
