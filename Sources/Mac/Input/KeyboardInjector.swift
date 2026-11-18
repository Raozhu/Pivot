import Foundation
import CoreGraphics

/// 把 iPad 外接键盘（如妙控键盘）的按键转成 Mac 的键盘事件。
/// iPad 上报的是 USB HID 键盘用途码，这里换成 Mac 的虚拟键码再投递。
final class KeyboardInjector {
    private let queue = DispatchQueue(label: "pivot.keys", qos: .userInteractive)
    private let source = CGEventSource(stateID: .hidSystemState)
    private var flags: CGEventFlags = []
    private var held = Set<UInt16>()

    /// 空跑：设置后不投递，只报告（自测用）
    var trace: ((String) -> Void)?

    /// HID 键盘用途码 → Mac 虚拟键码
    static let keyCodes: [UInt16: CGKeyCode] = {
        var m: [UInt16: CGKeyCode] = [:]
        // 字母 a…z（用途码 0x04 起）
        let letters: [CGKeyCode] = [0, 11, 8, 2, 14, 3, 5, 4, 34, 38, 40, 37, 46, 45, 31, 35, 12, 15, 1, 17, 32, 9, 13, 7, 16, 6]
        for (i, code) in letters.enumerated() { m[UInt16(0x04 + i)] = code }
        // 数字 1…9、0（0x1E 起）
        let digits: [CGKeyCode] = [18, 19, 20, 21, 23, 22, 26, 28, 25, 29]
        for (i, code) in digits.enumerated() { m[UInt16(0x1E + i)] = code }
        // 回车、Esc、退格、Tab、空格、- = [ ] \ （0x32 为非美式键盘的 #）; ' ` , . / 大写锁定
        let block: [CGKeyCode] = [36, 53, 51, 48, 49, 27, 24, 33, 30, 42, 42, 41, 39, 50, 43, 47, 44, 57]
        for (i, code) in block.enumerated() { m[UInt16(0x28 + i)] = code }
        // F1…F12（0x3A 起）
        let fkeys: [CGKeyCode] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]
        for (i, code) in fkeys.enumerated() { m[UInt16(0x3A + i)] = code }
        // 导航区：Home PageUp 前删 End PageDown → ← ↓ ↑
        m[0x4A] = 115; m[0x4B] = 116; m[0x4C] = 117; m[0x4D] = 119; m[0x4E] = 121
        m[0x4F] = 124; m[0x50] = 123; m[0x51] = 125; m[0x52] = 126
        // 修饰键：左 Ctrl Shift Option Cmd，右 Ctrl Shift Option Cmd
        m[0xE0] = 59; m[0xE1] = 56; m[0xE2] = 58; m[0xE3] = 55
        m[0xE4] = 62; m[0xE5] = 60; m[0xE6] = 61; m[0xE7] = 54
        return m
    }()

    private static func modifier(for usage: UInt16) -> CGEventFlags? {
        switch usage {
        case 0xE0, 0xE4: return .maskControl
        case 0xE1, 0xE5: return .maskShift
        case 0xE2, 0xE6: return .maskAlternate
        case 0xE3, 0xE7: return .maskCommand
        default: return nil
        }
    }

    func handle(usage: UInt16, down: Bool) {
        queue.async { [self] in
            guard let code = Self.keyCodes[usage] else { return }
            if down { held.insert(usage) } else { guard held.remove(usage) != nil else { return } }
            if let mod = Self.modifier(for: usage) {
                // 同一种修饰键左右都松开才算松开
                let stillHeld = held.contains { Self.modifier(for: $0) == mod }
                if down || stillHeld { flags.insert(mod) } else { flags.remove(mod) }
            }
            post(code: code, down: down)
        }
    }

    /// iPad 屏幕键盘输入的文字：不经键码，直接按字符投递，所以中文、表情都能输入
    func type(_ text: String) {
        queue.async { [self] in
            if let trace { trace("text \"\(text)\""); return }
            let units = Array(text.utf16)
            guard !units.isEmpty else { return }
            for down in [true, false] {
                guard let e = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else { continue }
                e.flags = []
                units.withUnsafeBufferPointer { e.keyboardSetUnicodeString(stringLength: $0.count, unicodeString: $0.baseAddress) }
                e.post(tap: .cghidEventTap)
            }
        }
    }

    /// 连接中断时松开所有还按着的键，避免 Mac 上出现「卡键」
    func releaseAll() {
        queue.async { [self] in
            let stuck = held
            held.removeAll()
            flags = []
            for usage in stuck {
                if let code = Self.keyCodes[usage] { post(code: code, down: false) }
            }
        }
    }

    func drain() { queue.sync {} }

    private func post(code: CGKeyCode, down: Bool) {
        if let trace {
            trace("key \(code) \(down ? "down" : "up") flags=0x\(String(flags.rawValue, radix: 16))")
            return
        }
        guard let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { return }
        e.flags = flags
        e.post(tap: .cghidEventTap)
    }
}
