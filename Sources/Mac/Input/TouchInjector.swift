import Foundation
import CoreGraphics

/// 把 iPad 传来的触点变成 Mac 上的输入。有两种实现：
/// - `HIDTouchscreenInjector`：注册一块虚拟触摸屏，手势完全由系统原生处理（需要受管权限）。
/// - `SyntheticInjector`：自己识别手势，再合成鼠标、滚动、缩放等事件（需要辅助功能授权）。
protocol TouchInjector: AnyObject {
    var label: String { get }
    /// 目标显示器或其模式发生变化
    func retarget(displayID: CGDirectDisplayID)
    func handle(_ packet: TouchPacket)
    /// 连接中断等情况下抬起所有按下的东西
    func reset()
    /// iPad 外接触控板或鼠标的滚动。phase：0 开始、1 变化、2 结束
    func pointerScroll(dx: Double, dy: Double, phase: UInt8)
}

extension TouchInjector {
    func pointerScroll(dx: Double, dy: Double, phase: UInt8) {}
}

enum InjectorFactory {
    /// 触摸屏驱动已启用、拿得到显示器 UUID 时用原生触摸屏，手指之外的输入仍走合成；否则全走合成手势。
    static func make(displayID: CGDirectDisplayID, displayUUID: String?, feedback: @escaping (Feedback) -> Void) -> TouchInjector {
        let synthetic = SyntheticInjector(displayID: displayID, feedback: feedback)
        synthetic.log = { Log.info($0) }
        if TouchDriverExtension.shared.active, let uuid = displayUUID,
           let hid = HIDTouchscreenInjector(displayID: displayID, displayUUID: uuid, fallback: synthetic) {
            return hid
        }
        return synthetic
    }
}
