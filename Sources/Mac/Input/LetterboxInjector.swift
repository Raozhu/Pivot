import Foundation
import CoreGraphics

/// 镜像模式：Mac 主屏的画面按原比例缩进 iPad 的画面里，上下或左右会留黑边。
/// 把 iPad 上的归一化坐标换算到主屏画面那一块，再交给真正的注入器。
final class LetterboxInjector: TouchInjector {
    private let inner: TouchInjector
    private let displayID: CGDirectDisplayID
    private let lock = NSLock()
    /// 主屏画面在 iPad 画面里的位置（归一化）
    private var content = CGRect(x: 0, y: 0, width: 1, height: 1)

    var label: String { inner.label }

    init(inner: TouchInjector, displayID: CGDirectDisplayID, viewport: Viewport) {
        self.inner = inner
        self.displayID = displayID
        update(viewport: viewport)
    }

    func update(viewport: Viewport) {
        let b = CGDisplayBounds(displayID)
        guard viewport.width > 0, viewport.height > 0, b.width > 0, b.height > 0 else { return }
        let vw = Double(viewport.width), vh = Double(viewport.height)
        let s = min(vw / b.width, vh / b.height)
        let w = b.width * s / vw, h = b.height * s / vh
        lock.lock()
        content = CGRect(x: (1 - w) / 2, y: (1 - h) / 2, width: w, height: h)
        lock.unlock()
    }

    func retarget(displayID: CGDirectDisplayID) { inner.retarget(displayID: displayID) }

    func handle(_ packet: TouchPacket) {
        lock.lock(); let r = content; lock.unlock()
        var p = packet
        for i in p.contacts.indices {
            let x = (Double(p.contacts[i].x) - r.minX) / r.width
            let y = (Double(p.contacts[i].y) - r.minY) / r.height
            p.contacts[i].x = Float(min(1, max(0, x)))
            p.contacts[i].y = Float(min(1, max(0, y)))
        }
        inner.handle(p)
    }

    func reset() { inner.reset() }

    func pointerScroll(dx: Double, dy: Double, phase: UInt8) { inner.pointerScroll(dx: dx, dy: dy, phase: phase) }
}
