// 验证合成的缩放、旋转、滚动事件能被本机系统正确解析。只构造和解码，不投递，不需要任何授权。
// 用法：swift scripts/gesture-decode-check.swift
import AppKit

func gesture(hidType: Int64, valueField: UInt32, value: Double, phase: Int64) -> NSEvent? {
    guard let e = CGEvent(source: nil) else { return nil }
    e.type = CGEventType(rawValue: 29)!
    e.setIntegerValueField(CGEventField(rawValue: 110)!, value: hidType)
    e.setIntegerValueField(CGEventField(rawValue: 132)!, value: phase)
    e.setDoubleValueField(CGEventField(rawValue: valueField)!, value: value)
    return NSEvent(cgEvent: e)
}

var failures = 0
func check(_ ok: Bool, _ what: String) {
    print(ok ? "✓ \(what)" : "✗ \(what)")
    if !ok { failures += 1 }
}

if let m = gesture(hidType: 8, valueField: 113, value: 0.25, phase: 2) {
    check(m.type == .magnify && abs(m.magnification - 0.25) < 0.001 && m.phase == .changed,
          "缩放：类型 \(m.type.rawValue)（应为 30），缩放量 \(m.magnification)，阶段 \(m.phase.rawValue)")
} else { check(false, "缩放事件无法构造") }

for field in [UInt32(114), 113] {
    if let r = gesture(hidType: 5, valueField: field, value: 12.5, phase: 2) {
        let ok = r.type == .rotate && abs(r.rotation - 12.5) < 0.01
        print("  旋转量放在 \(field) 号字段 → 类型 \(r.type.rawValue)（应为 18），旋转量 \(r.rotation) \(ok ? "✓" : "✗")")
        if field == 114 { check(ok, "旋转：114 号字段可用") }
    }
}

for (phase, expected) in [(Int64(1), NSEvent.Phase.began), (4, .ended)] {
    if let m = gesture(hidType: 8, valueField: 113, value: 0, phase: phase) {
        check(m.type == .magnify && m.phase == expected, "缩放阶段 \(phase) 解析为 \(m.phase.rawValue)")
    }
}

if let s = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: -24, wheel2: 3, wheel3: 0) {
    s.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
    s.setIntegerValueField(.scrollWheelEventScrollPhase, value: 2)
    if let n = NSEvent(cgEvent: s) {
        check(n.type == .scrollWheel && n.hasPreciseScrollingDeltas && n.scrollingDeltaY == -24 && n.scrollingDeltaX == 3 && n.phase == .changed,
              "滚动：dy \(n.scrollingDeltaY) dx \(n.scrollingDeltaX) 精确 \(n.hasPreciseScrollingDeltas) 阶段 \(n.phase.rawValue)")
    }
    s.setIntegerValueField(.scrollWheelEventScrollPhase, value: 0)
    s.setIntegerValueField(.scrollWheelEventMomentumPhase, value: 2)
    if let n = NSEvent(cgEvent: s) {
        check(n.momentumPhase == .changed, "惯性滚动阶段解析为 \(n.momentumPhase.rawValue)")
    }
}
print(failures == 0 ? "全部通过" : "有 \(failures) 项失败")
exit(failures == 0 ? 0 : 1)
