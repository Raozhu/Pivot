import Foundation
import CoreGraphics

/// 手势识别器的空跑自测：`Pivot --gesture-selftest`。
/// 喂入脚本化的触点序列，打印识别器本应投递的事件，不触碰真实输入。
/// 虚拟屏幕为 1000×1000 点，左半边视为可滚动内容，右半边视为不可滚动（如标题栏）。
enum GestureSelfTest {
    private static var clock: UInt64 = 1_000_000_000

    static func run() {
        var lines: [String] = []
        let lock = NSLock()
        let injector = SyntheticInjector(displayID: CGMainDisplayID()) { fb in
            lock.lock(); lines.append("  ↩︎ 反馈 \(fb.kind.rawValue)"); lock.unlock()
        }
        injector.boundsOverride = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        injector.scrollableOverride = { $0.x < 500 }
        injector.trace = { s in lock.lock(); lines.append("  " + s); lock.unlock() }
        injector.retarget(displayID: CGMainDisplayID())

        func send(_ contacts: [(id: UInt8, phase: TouchPhase, x: Double, y: Double)], kind: TouchKind = .finger, pressure: Float = 1, after ms: Double = 8) {
            usleep(UInt32(ms * 1000))
            clock += UInt64(ms * 1_000_000)
            injector.handle(TouchPacket(timestamp: clock, contacts: contacts.map {
                TouchContact(id: $0.id, phase: $0.phase, kind: kind, x: Float($0.x), y: Float($0.y), pressure: pressure, altitude: .pi / 3, azimuth: 0, radius: 20)
            }))
        }
        /// 打印一段手势的结果；重复的同类事件折叠成计数
        func section(_ title: String, settle: Double = 0.1) {
            usleep(UInt32(settle * 1_000_000))
            injector.drain()
            lock.lock()
            let captured = lines
            lines.removeAll()
            lock.unlock()
            print("【\(title)】")
            var last = ""
            var count = 0
            func flush() {
                if !last.isEmpty { print(count > 1 ? "\(last)  ×\(count)" : last) }
            }
            for line in captured {
                let key = line.split(separator: " ").prefix(1).joined() + (line.contains("phase=") ? String(line.suffix(18)) : "")
                let lastKey = last.split(separator: " ").prefix(1).joined() + (last.contains("phase=") ? String(last.suffix(18)) : "")
                if key == lastKey, line.contains("leftDrag") || line.contains("scroll") || line.contains("magnify") || line.contains("rotate") {
                    count += 1
                    last = line
                } else {
                    flush()
                    last = line
                    count = 1
                }
            }
            flush()
        }
        func drag(_ id: UInt8, from: (Double, Double), to: (Double, Double), steps: Int = 12, stepMs: Double = 8) {
            for i in 1...steps {
                let t = Double(i) / Double(steps)
                send([(id, .moved, from.0 + (to.0 - from.0) * t, from.1 + (to.1 - from.1) * t)], after: stepMs)
            }
        }

        // 1. 轻点
        send([(0, .began, 0.7, 0.5)]); send([(0, .ended, 0.7, 0.5)], after: 60)
        section("单指轻点 → 应为一次左键单击")

        // 2. 双击
        usleep(500_000)
        send([(0, .began, 0.7, 0.5)]); send([(0, .ended, 0.7, 0.5)], after: 50)
        send([(0, .began, 0.702, 0.501)], after: 120); send([(0, .ended, 0.702, 0.501)], after: 50)
        section("快速两次轻点 → 第二次 clicks=2，位置钉在第一次")

        // 3. 不可滚动区域拖动
        usleep(400_000)
        send([(0, .began, 0.8, 0.2)]); drag(0, from: (0.8, 0.2), to: (0.6, 0.4)); send([(0, .ended, 0.6, 0.4)])
        section("右半边（不可滚动）单指滑动 → 应为按下、拖动、抬起")

        // 4. 可滚动区域快速滑动，带惯性
        send([(0, .began, 0.2, 0.7)]); drag(0, from: (0.2, 0.7), to: (0.2, 0.4)); send([(0, .ended, 0.2, 0.4)])
        section("左半边（可滚动）单指上滑后松手 → 滚动 began/changed/ended，随后惯性 1/2/3", settle: 2.5)

        // 5. 长按后抬起
        send([(0, .began, 0.2, 0.5)]); send([(0, .ended, 0.2, 0.5)], after: 600)
        section("长按后抬起 → 长按反馈 + 右键")

        // 6. 长按后拖动（在可滚动区域里拖拽）
        send([(0, .began, 0.2, 0.5)]); usleep(550_000); clock += 550_000_000
        drag(0, from: (0.2, 0.5), to: (0.3, 0.6)); send([(0, .ended, 0.3, 0.6)])
        section("可滚动区域长按后移动 → 长按反馈 + 拖拽开始反馈 + 按下、拖动、抬起")

        // 7. 双指滚动
        send([(0, .began, 0.6, 0.6)]); send([(1, .began, 0.7, 0.6)], after: 10)
        for i in 1...12 { let y = 0.6 - 0.2 * Double(i) / 12; send([(0, .moved, 0.6, y), (1, .moved, 0.7, y)]) }
        send([(0, .ended, 0.6, 0.4), (1, .ended, 0.7, 0.4)])
        section("双指上滑 → 滚动（在不可滚动区域也应滚动），随后惯性", settle: 2.5)

        // 8. 双指轻点
        send([(0, .began, 0.6, 0.6)]); send([(1, .began, 0.7, 0.6)], after: 10)
        send([(0, .ended, 0.6, 0.6), (1, .ended, 0.7, 0.6)], after: 70)
        section("双指轻点 → 右键")

        // 9. 捏合放大
        send([(0, .began, 0.45, 0.5)]); send([(1, .began, 0.55, 0.5)], after: 10)
        for i in 1...12 { let d = 0.05 + 0.15 * Double(i) / 12; send([(0, .moved, 0.5 - d, 0.5), (1, .moved, 0.5 + d, 0.5)]) }
        send([(0, .ended, 0.3, 0.5), (1, .ended, 0.7, 0.5)])
        section("双指张开 → magnify 开始、若干正值、结束")

        // 10. 三指左滑
        send([(0, .began, 0.6, 0.5)]); send([(1, .began, 0.7, 0.5)], after: 8); send([(2, .began, 0.8, 0.5)], after: 8)
        for i in 1...10 { let dx = 0.15 * Double(i) / 10; send([(0, .moved, 0.6 - dx, 0.5), (1, .moved, 0.7 - dx, 0.5), (2, .moved, 0.8 - dx, 0.5)]) }
        send([(0, .ended, 0.45, 0.5), (1, .ended, 0.55, 0.5), (2, .ended, 0.65, 0.5)])
        section("三指左滑 → 切到下一个桌面，且只触发一次")

        // 11. 笔迹
        send([(9, .began, 0.3, 0.3)], kind: .pencil, pressure: 0.2)
        for i in 1...6 { send([(9, .moved, 0.3 + 0.02 * Double(i), 0.3)], kind: .pencil, pressure: 0.2 + 0.1 * Float(i)) }
        send([(9, .ended, 0.42, 0.3)], kind: .pencil, pressure: 0)
        section("Apple Pencil 画一笔 → 接近事件、带压感的按下/拖动/抬起")

        // 12. 惯性中按住刹车（先等笔的防误触窗口过去）
        usleep(400_000)
        send([(0, .began, 0.2, 0.7)]); drag(0, from: (0.2, 0.7), to: (0.2, 0.4)); send([(0, .ended, 0.2, 0.4)])
        send([(0, .began, 0.2, 0.5)], after: 200); send([(0, .ended, 0.2, 0.5)], after: 60)
        section("惯性滚动中轻点 → 惯性立即结束（momentum=3），且不产生点击")

        // 13. 外接触控板滚动
        usleep(300_000)
        injector.pointerScroll(dx: 0, dy: -12, phase: 0)
        for _ in 0..<6 { usleep(8000); injector.pointerScroll(dx: 0, dy: -12, phase: 1) }
        usleep(8000); injector.pointerScroll(dx: 0, dy: 0, phase: 2)
        section("iPad 外接触控板滚动 → 滚动 began/changed/ended（速度够快时带惯性）", settle: 1.5)

        // 14. 外接键盘：Cmd+C，以及断线时松开卡住的键
        let keyboard = KeyboardInjector()
        keyboard.trace = { s in lock.lock(); lines.append("  " + s); lock.unlock() }
        keyboard.handle(usage: 0xE3, down: true)   // 左 Cmd
        keyboard.handle(usage: 0x06, down: true)   // C
        keyboard.handle(usage: 0x06, down: false)
        keyboard.handle(usage: 0xE3, down: false)
        keyboard.handle(usage: 0xE1, down: true)   // 按住 Shift 时断线
        keyboard.releaseAll()
        keyboard.drain()
        section("外接键盘 Cmd+C → 55↓ 8↓(带 Cmd 标志) 8↑ 55↑；随后 Shift(56) 按下后被强制松开")
    }
}
