import AppKit
import CoreGraphics

/// 手指触控时把鼠标指针藏起来，让画面看起来像真正的触摸屏，而不是「指针跳到手指下面」。
/// 真鼠标一动、或者改用 Apple Pencil / 触控板时，指针立刻回来。
///
/// 做法：合成的事件都带一个标记；全局监听鼠标事件，凡是不带标记的就是用户在动真鼠标。
/// 指针的隐藏只在本进程存活期间有效，进程退出时系统会自动恢复。
enum TouchCursor {
    /// 写在事件「来源自定义数据」字段里的标记
    static let eventTag: Int64 = 0x5049_564F_54   // "PIVOT"

    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "hideCursorOnTouch") as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: "hideCursorOnTouch")
            if !newValue { show() }
        }
    }

    private static let lock = NSLock()
    private static var hidden = false
    private static var prepared = false
    private static var monitor: Any?

    private static func prepare() {
        guard !prepared else { return }
        prepared = true
        // 默认只有前台应用能隐藏指针；打开这个连接属性后后台应用也可以
        let connection = CGSMainConnectionID()
        _ = CGSSetConnectionProperty(connection, connection, "SetsCursorInBackground" as CFString, kCFBooleanTrue)
        DispatchQueue.main.async {
            let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDown, .rightMouseDown, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
            monitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { event in
                // 不带标记的鼠标事件来自真实的鼠标或触控板
                if event.cgEvent?.getIntegerValueField(.eventSourceUserData) != eventTag { show() }
            }
        }
    }

    /// 手指触控开始时调用
    static func hide() {
        guard enabled else { return }
        lock.lock(); defer { lock.unlock() }
        prepare()
        guard !hidden else { return }
        hidden = true
        CGDisplayHideCursor(CGMainDisplayID())
    }

    /// 需要看到指针时调用（真鼠标、Pencil、触控板、会话结束）
    static func show() {
        lock.lock(); defer { lock.unlock() }
        guard hidden else { return }
        hidden = false
        CGDisplayShowCursor(CGMainDisplayID())
    }

    /// 给合成的事件打上标记
    static func tag(_ event: CGEvent) {
        event.setIntegerValueField(.eventSourceUserData, value: eventTag)
    }
}
