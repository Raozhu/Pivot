// 压力测试：在名为 Pivot 的显示器上铺一个持续动画的窗口，持续若干秒。
// 用法：swift scripts/motion-test.swift [秒数]
import AppKit

final class MotionView: NSView {
    var t: CGFloat = 0
    override var isFlipped: Bool { true }
    override func draw(_ dirty: NSRect) {
        NSColor(calibratedWhite: 0.96, alpha: 1).setFill()
        bounds.fill()
        // 滚动的文字，模拟阅读和滚动网页
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 15), .foregroundColor: NSColor.black]
        let lineHeight: CGFloat = 22
        let offset = (t * 240).truncatingRemainder(dividingBy: lineHeight)
        var y = -offset
        var row = Int(t * 240 / lineHeight)
        while y < bounds.height {
            ("第 \(row) 行 · The quick brown fox jumps over the lazy dog · 敏捷的棕色狐狸跳过懒狗 0123456789" as NSString)
                .draw(at: NSPoint(x: 24, y: y), withAttributes: attrs)
            y += lineHeight
            row += 1
        }
        // 来回移动的色块，模拟拖动窗口
        let w = bounds.width - 220
        let x = 20 + (sin(t * 2.2) * 0.5 + 0.5) * w
        NSColor.systemBlue.setFill()
        NSBezierPath(roundedRect: NSRect(x: x, y: bounds.height * 0.4, width: 180, height: 120), xRadius: 18, yRadius: 18).fill()
    }
}

let seconds = CommandLine.arguments.count > 1 ? Double(CommandLine.arguments[1]) ?? 6 : 6
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
guard let screen = NSScreen.screens.first(where: { $0.localizedName.contains("Pivot") }) else {
    print("没有找到 Pivot 显示器：", NSScreen.screens.map(\.localizedName))
    exit(1)
}
print("Pivot 显示器 \(Int(screen.frame.width))x\(Int(screen.frame.height)) 点，缩放 \(screen.backingScaleFactor)x，刷新率 \(screen.maximumFramesPerSecond)")
let window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
let view = MotionView(frame: NSRect(origin: .zero, size: screen.frame.size))
window.contentView = view
window.setFrame(screen.frame, display: true)
window.orderFrontRegardless()
let start = Date()
let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { _ in
    view.t = CGFloat(Date().timeIntervalSince(start))
    view.needsDisplay = true
    if Date().timeIntervalSince(start) > seconds { exit(0) }
}
RunLoop.main.add(timer, forMode: .common)
app.run()
