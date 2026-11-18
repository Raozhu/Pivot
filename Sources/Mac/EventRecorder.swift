import AppKit
import CoreGraphics

/// 录制模式：`Pivot --record-events`。
/// 旁听系统输入事件流并写到 ~/Library/Logs/PivotEvents.log，用来研究随航触控时系统实际产生了哪些事件。
/// 键盘事件一律不记录。只观察，不修改任何事件。
enum EventRecorder {
    static let fileURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/PivotEvents.log")
    private static var out: FileHandle?
    private static var tap: CFMachPort?
    private static var counts: [UInt32: Int] = [:]
    private static var dumped: [UInt32: Int] = [:]
    private static var started: UInt64 = 0

    private static func write(_ line: String) {
        out?.write(Data((line + "\n").utf8))
    }

    static func run() {
        started = monotonicNs()
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        out = try? FileHandle(forWritingTo: fileURL)
        write("录制开始。辅助功能权限：\(AXIsProcessTrusted())")
        for (i, id) in activeDisplays().enumerated() {
            let b = CGDisplayBounds(id)
            write("显示器 \(i)：编号 \(id) 厂商 0x\(String(CGDisplayVendorNumber(id), radix: 16)) 范围 \(Int(b.minX)),\(Int(b.minY)) \(Int(b.width))x\(Int(b.height))")
        }
        let callback: CGEventTapCallBack = { _, type, event, _ in
            EventRecorder.record(type, event)
            return Unmanaged.passUnretained(event)
        }
        write("输入监控权限：\(CGPreflightListenEventAccess())，投递事件权限：\(CGPreflightPostEventAccess())")
        // 用默认方式（靠已授予的辅助功能权限）。「只听」方式需要输入监控权限，没有的话句柄能建出来但收不到事件。
        for options in [CGEventTapOptions.defaultTap, .listenOnly] {
            if let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: options,
                                            eventsOfInterest: ~0, callback: callback, userInfo: nil) {
                tap = port
                write("事件监听已建立（\(options == .listenOnly ? "只听" : "默认")）")
                break
            }
        }
        guard let tap else { write("无法建立事件监听"); return }
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private static func activeDisplays() -> [CGDirectDisplayID] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var n: UInt32 = 0
        CGGetActiveDisplayList(16, &ids, &n)
        return Array(ids.prefix(Int(n)))
    }

    private static func record(_ type: CGEventType, _ e: CGEvent) {
        let raw = type.rawValue
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        // 不记录键盘
        if raw == 10 || raw == 11 || raw == 12 { return }
        counts[raw, default: 0] += 1
        let n = counts[raw]!
        // 鼠标移动量大，只记前几条和之后每 40 条一条
        if raw == 5, n > 6, n % 40 != 0 { return }

        func i(_ f: UInt32) -> Int64 { e.getIntegerValueField(CGEventField(rawValue: f)!) }
        func d(_ f: UInt32) -> Double { e.getDoubleValueField(CGEventField(rawValue: f)!) }
        let now = monotonicNs()
        let ms = Double(now > started ? now - started : 0) / 1e6
        var line = String(format: "[%9.1f] 类型 %2u 位置 (%.0f,%.0f) 来源进程 %lld 来源状态 %lld 标记 0x%llx 标志 0x%llx",
                          ms, raw, e.location.x, e.location.y, i(41), i(45), i(42), e.flags.rawValue)
        switch raw {
        case 1, 2, 3, 4, 5, 6, 7, 25, 26, 27:
            line += String(format: " | 鼠标：子类型 %lld 连击 %lld 压力 %.2f 按钮 %lld 事件号 %lld", i(7), i(1), d(2), i(3), i(0))
        case 22:
            line += String(format: " | 滚动：dy %.1f dx %.1f 行dy %lld 连续 %lld 阶段 %lld 惯性 %lld 计数 %lld", d(96), d(97), i(11), i(88), i(99), i(123), i(100))
        default:
            line += String(format: " | 其他：f110 %lld f132 %lld f113 %.3f f114 %.3f f115 %.3f f123 %lld f124 %.3f", i(110), i(132), d(113), d(114), d(115), i(123), d(124))
        }
        write(line)

        // 每种类型的前若干条：附上 AppKit 的解析结果和原始数据，供逐字节比对
        let limit = raw == 5 ? 2 : 10
        if dumped[raw, default: 0] < limit {
            dumped[raw, default: 0] += 1
            if raw >= 18, raw != 22, raw != 25, raw != 26, raw != 27, let ns = NSEvent(cgEvent: e) {
                var text = "    AppKit：类型 \(ns.type.rawValue) 子类型 \(ns.subtype.rawValue)"
                if ns.type == .gesture || ns.type == .directTouch || ns.type == .magnify || ns.type == .rotate {
                    let touches = ns.allTouches()
                    text += " 触点 \(touches.count)"
                    for t in touches.prefix(4) { text += " [类型 \(t.type.rawValue) 阶段 \(t.phase.rawValue)]" }
                }
                write(text)
            }
            if let data = e.data as Data? {
                write("    原始 \(data.count) 字节：\(data.base64EncodedString())")
            }
        }
    }
}
