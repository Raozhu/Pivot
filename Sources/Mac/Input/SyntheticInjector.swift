import Foundation
import CoreGraphics
import ApplicationServices

/// 合成路线：自己识别手势，再向系统投递鼠标、滚动、缩放、旋转事件。
///
/// 手势约定（尽量贴近 iPad 的直觉）：
/// - 单指轻点＝点击，连点＝双击/三击
/// - 单指在可滚动内容上滑动＝滚动（带惯性）；在标题栏、滑块等处滑动＝直接拖拽
/// - 长按后移动＝拖拽（选字、拖文件）；长按后抬起＝右键菜单
/// - 双指滑动＝滚动；双指轻点＝右键；双指捏合＝缩放；双指扭转＝旋转
/// - 三指左右滑＝切换桌面；三指上滑＝调度中心；三指下滑＝应用窗口
/// - Apple Pencil＝带压感和倾斜的笔；悬停＝移动指针
final class SyntheticInjector: TouchInjector {
    let label = "合成手势"

    private let queue = DispatchQueue(label: "pivot.inject", qos: .userInteractive)
    private var displayID: CGDirectDisplayID
    private var bounds: CGRect
    private let feedback: (Feedback) -> Void
    private let source = CGEventSource(stateID: .hidSystemState)
    private let systemWide = AXUIElementCreateSystemWide()

    // 手感参数
    /// 双指、长按后拖动等场合的移动判定
    private let slop: CGFloat = 9
    /// 单指「点按还是滑动」的容差。手指按下时总会有点滑动，太小会把点按误判成滚动
    private let tapSlop: CGFloat = 16
    private let longPressDelay = 0.4
    /// 长按不动到这个时长，直接弹出右键菜单
    private let contextMenuDelay = 0.95
    /// 点击时按下保持的时长，让按钮来得及显示按下状态
    private let clickHold = 0.04
    /// 距屏幕上下边缘多近算「从边缘滑入」
    private let edgeBand: CGFloat = 12
    private let multiTapInterval = 0.32
    private let multiTapDistance: CGFloat = 28
    private let twoFingerTapDuration = 0.30
    private let swipeDistance: CGFloat = 70

    private struct Finger {
        var start: CGPoint
        var pos: CGPoint
        var norm: CGPoint
        var startTime: Double
    }

    private enum Mode {
        case idle
        case pending            // 单指按下，尚未判定
        case longPressed        // 已长按，等待移动（拖拽）或抬起（右键）
        case dragging(UInt8)
        case scrolling(UInt8?)  // 单指 id；nil 表示双指质心
        case twoPending
        case pinching
        case multi
        case swallow            // 手势已结束，等所有手指抬起
    }

    private var mode: Mode = .idle
    private var fingers: [UInt8: Finger] = [:]
    private var order: [UInt8] = []
    private var ignoredFingers = Set<UInt8>()
    private var scrollableAtStart = false
    private var tapSuppressed = false
    private var longPressWork: DispatchWorkItem?
    private var contextMenuWork: DispatchWorkItem?
    /// 本次单指触摸是否从上（-1）或下（1）边缘开始
    private var edgeStart = 0

    // 连点
    private var lastTapTime = 0.0
    private var lastTapPoint = CGPoint.zero
    private var tapCount = 0

    // 双指
    private var twoStartTime = 0.0
    private var twoStartCentroid = CGPoint.zero
    private var twoStartDistance: CGFloat = 0
    private var twoStartAngle: CGFloat = 0
    private var twoPrevDistance: CGFloat = 0
    private var twoPrevAngle: CGFloat = 0
    private var twoMoved = false
    private var rotating = false
    private var twoTapPoint = CGPoint.zero

    // 多指
    private var multiCount = 0
    private var multiStart = CGPoint.zero

    // 滚动
    private var scrollStarted = false
    private var lastScrollPoint = CGPoint.zero
    private var scrollResidual = CGPoint.zero
    private var scrollSamples: [(t: Double, d: CGPoint)] = []
    private var momentumTimer: DispatchSourceTimer?
    private var momentumVelocity = CGPoint.zero

    // 笔 / 指针
    private var pointerDown = false
    private var pointerIsPencil = false
    private var lastPointerDownTime = 0.0
    private var lastPointerDownPoint = CGPoint.zero
    private var pointerClicks: Int64 = 1
    private var lastPointerActivity = 0.0

    /// 空跑：设置后不向系统投递任何事件，只把本应投递的内容交给它（自测用）
    var trace: ((String) -> Void)?
    /// 空跑时代替辅助功能命中测试
    var scrollableOverride: ((CGPoint) -> Bool)?
    /// 空跑时代替真实的显示器范围
    var boundsOverride: CGRect?

    private func currentBounds() -> CGRect { boundsOverride ?? CGDisplayBounds(displayID) }

    /// 等内部队列处理完（自测用）
    func drain() { queue.sync {} }

    init(displayID: CGDirectDisplayID, feedback: @escaping (Feedback) -> Void) {
        self.displayID = displayID
        self.bounds = CGDisplayBounds(displayID)
        self.feedback = feedback
        AXUIElementSetMessagingTimeout(systemWide, 0.12)
    }

    func retarget(displayID: CGDirectDisplayID) {
        queue.async { [self] in
            self.displayID = displayID
            bounds = currentBounds()
        }
    }

    func handle(_ packet: TouchPacket) {
        queue.async { [self] in process(packet) }
    }

    func reset() {
        queue.async { [self] in
            cancelLongPress()
            stopMomentum()
            switch mode {
            case .dragging(let id): postMouse(.leftMouseUp, fingers[id]?.pos ?? cursorPoint())
            case .scrolling: postScroll(dx: 0, dy: 0, phase: 4, momentum: 0)
            case .pinching: postGesture(hidType: 8, value: 0, phase: 4)
            default: break
            }
            if pointerDown { postMouse(.leftMouseUp, cursorPoint()); pointerDown = false }
            mode = .idle
            fingers.removeAll(); order.removeAll(); ignoredFingers.removeAll()
            TouchCursor.show()
        }
    }

    func pointerScroll(dx: Double, dy: Double, phase: UInt8) {
        queue.async { [self] in
            let t = now()
            switch phase {
            case 0:
                stopMomentum()
                scrollStarted = false
                scrollResidual = .zero
                scrollSamples.removeAll(keepingCapacity: true)
                scroll(by: CGPoint(x: dx, y: dy), t)
            case 1:
                scroll(by: CGPoint(x: dx, y: dy), t)
            default:
                endScroll(t, cancelled: false)
            }
        }
    }

    // MARK: - 分发

    private func process(_ packet: TouchPacket) {
        let t = Double(packet.timestamp) / 1e9
        var moved = false
        for c in packet.contacts {
            let p = point(c)
            switch c.kind {
            case .pencil, .pointer:
                handlePointer(c, p)
            case .hover:
                handleHover(c, p)
            case .finger:
                switch c.phase {
                case .began:
                    fingerBegan(c.id, p, norm: CGPoint(x: CGFloat(c.x), y: CGFloat(c.y)), t)
                case .moved, .stationary:
                    if fingers[c.id] != nil { fingers[c.id]!.pos = p; moved = true }
                case .ended, .cancelled:
                    if moved { fingersMoved(t); moved = false }
                    if fingers[c.id] != nil { fingers[c.id]!.pos = p }
                    fingerEnded(c.id, cancelled: c.phase == .cancelled, t)
                }
            }
        }
        if moved { fingersMoved(t) }
    }

    private func point(_ c: TouchContact) -> CGPoint {
        CGPoint(x: bounds.minX + CGFloat(c.x) * bounds.width, y: bounds.minY + CGFloat(c.y) * bounds.height)
    }

    // MARK: - 手指状态机

    private func fingerBegan(_ id: UInt8, _ p: CGPoint, norm: CGPoint, _ t: Double) {
        // 防误触：笔在用时忽略手掌
        if pointerDown && pointerIsPencil || (pointerIsPencil && now() - lastPointerActivity < 0.25) {
            ignoredFingers.insert(id)
            return
        }
        fingers[id] = Finger(start: p, pos: p, norm: norm, startTime: t)
        order.append(id)
        if trace == nil { TouchCursor.hide() }

        switch mode {
        case .idle:
            bounds = currentBounds()
            tapSuppressed = stopMomentum()   // 惯性滚动中按住只是刹车，不算点击
            scrollableAtStart = !dragsDirectly(at: p)
            edgeStart = p.y - bounds.minY < edgeBand ? -1 : (bounds.maxY - p.y < edgeBand ? 1 : 0)
            note(String(format: "手指按下 (%.0f,%.0f)，下方%@（%@）", p.x, p.y, scrollableAtStart ? "按滚动处理" : "直接拖拽", lastHitTrail))
            mode = .pending
            scheduleLongPress()
        case .pending, .longPressed:
            cancelLongPress()
            note("第二根手指按下 → 双指待定")
            beginTwoFinger(t)
        case .twoPending:
            mode = .multi
            multiCount = fingers.count
            multiStart = centroid()
        case .multi:
            multiCount = max(multiCount, fingers.count)
            multiStart = centroid()
        default:
            break
        }
    }

    private func beginTwoFinger(_ t: Double) {
        guard order.count >= 2, let a = fingers[order[0]], let b = fingers[order[1]] else { return }
        mode = .twoPending
        twoStartTime = t
        twoStartCentroid = mid(a.pos, b.pos)
        twoStartDistance = dist(a.pos, b.pos)
        twoStartAngle = angle(a.pos, b.pos)
        twoPrevDistance = twoStartDistance
        twoPrevAngle = twoStartAngle
        twoMoved = false
        rotating = false
        twoTapPoint = a.start
    }

    private func fingersMoved(_ t: Double) {
        switch mode {
        case .pending:
            guard let id = order.first, let f = fingers[id], dist(f.start, f.pos) > tapSlop else { return }
            cancelLongPress()
            let inward = edgeStart == -1 ? f.pos.y - f.start.y : f.start.y - f.pos.y
            if edgeStart != 0, inward > tapSlop * 0.7 {
                // 从上/下边缘滑入：把指针送到屏幕边缘，呼出自动隐藏的菜单栏或程序坞
                note(edgeStart == -1 ? "上边缘滑入 → 菜单栏" : "下边缘滑入 → 程序坞")
                postMouse(.mouseMoved, CGPoint(x: f.pos.x, y: edgeStart == -1 ? bounds.minY : bounds.maxY - 1))
                mode = .swallow
            } else if scrollableAtStart {
                note("单指滑动 → 滚动")
                // 从按下的位置算起，把判定期间手指已经走过的那一段补上，内容才跟手
                beginScroll(at: f.start, from: f.start)
                scroll(by: CGPoint(x: f.pos.x - f.start.x, y: f.pos.y - f.start.y), t)
                lastScrollPoint = f.pos
                mode = .scrolling(id)
            } else {
                note("单指滑动 → 拖拽")
                beginDrag(id, f)
            }
        case .longPressed:
            guard let id = order.first, let f = fingers[id], dist(f.start, f.pos) > slop * 0.6 else { return }
            cancelLongPress()
            feedback(Feedback(kind: .dragStart, x: Double(f.norm.x), y: Double(f.norm.y)))
            beginDrag(id, f)
        case .dragging(let id):
            if let f = fingers[id] { postMouse(.leftMouseDragged, f.pos) }
        case .scrolling(let id):
            let p: CGPoint
            if let id { guard let f = fingers[id] else { return }; p = f.pos } else { guard fingers.count >= 2 else { return }; p = twoCentroid() }
            scroll(by: CGPoint(x: p.x - lastScrollPoint.x, y: p.y - lastScrollPoint.y), t)
            lastScrollPoint = p
        case .twoPending:
            guard order.count >= 2, let a = fingers[order[0]], let b = fingers[order[1]] else { return }
            let c = mid(a.pos, b.pos), d = dist(a.pos, b.pos), ang = angle(a.pos, b.pos)
            let dCentroid = dist(c, twoStartCentroid)
            let dDistance = d - twoStartDistance
            let dAngle = angleDelta(ang, twoStartAngle)
            if dCentroid > slop * 0.5 || abs(dDistance) > slop * 0.5 { twoMoved = true }
            if abs(dDistance) > 16, abs(dDistance) > dCentroid * 1.1 {
                note("双指 → 缩放")
                beginPinch(at: c, distance: d, angle: ang, rotating: false)
            } else if abs(dAngle) > 12, d > 60, dCentroid < 24 {
                note("双指 → 旋转")
                beginPinch(at: c, distance: d, angle: ang, rotating: true)
            } else if dCentroid > slop {
                note("双指 → 滚动")
                beginScroll(at: twoStartCentroid, from: c)
                mode = .scrolling(nil)
            }
        case .pinching:
            guard order.count >= 2, let a = fingers[order[0]], let b = fingers[order[1]] else { return }
            let d = dist(a.pos, b.pos), ang = angle(a.pos, b.pos)
            if twoPrevDistance > 1 {
                let magnification = Double(d / twoPrevDistance - 1)
                if abs(magnification) > 0.0005 { postGesture(hidType: 8, value: magnification, phase: 2) }
            }
            let dAngle = angleDelta(ang, twoPrevAngle)
            if !rotating, abs(angleDelta(ang, twoStartAngle)) > 10 { rotating = true; postGesture(hidType: 5, value: 0, phase: 1) }
            if rotating, abs(dAngle) > 0.05 { postGesture(hidType: 5, value: Double(-dAngle), phase: 2) }
            twoPrevDistance = d
            twoPrevAngle = ang
        case .multi:
            guard fingers.count == multiCount else { return }
            let c = centroid()
            let dx = c.x - multiStart.x, dy = c.y - multiStart.y
            guard max(abs(dx), abs(dy)) > swipeDistance else { return }
            performSwipe(dx: dx, dy: dy, fingers: multiCount)
            mode = .swallow
        case .idle, .swallow:
            break
        }
    }

    private func fingerEnded(_ id: UInt8, cancelled: Bool, _ t: Double) {
        if ignoredFingers.remove(id) != nil { return }
        guard let f = fingers.removeValue(forKey: id) else { return }
        order.removeAll { $0 == id }
        let allUp = fingers.isEmpty
        if cancelled { note("触点被 iPad 取消（\(modeName)）") } else if allUp { note("全部抬起（\(modeName)）") }

        switch mode {
        case .pending:
            cancelLongPress()
            if !cancelled && !tapSuppressed { tap(at: f.pos) }
            mode = .idle
        case .longPressed:
            cancelLongPress()
            if !cancelled {
                feedback(Feedback(kind: .rightClick, x: Double(f.norm.x), y: Double(f.norm.y)))
                rightClick(at: f.start)
            }
            mode = .idle
        case .dragging(let dragID):
            if dragID == id {
                postMouse(.leftMouseUp, f.pos)
                mode = allUp ? .idle : .swallow
            }
        case .scrolling(let scrollID):
            if scrollID == nil || scrollID == id {
                endScroll(t, cancelled: cancelled)
                mode = allUp ? .idle : .swallow
            }
        case .twoPending:
            if allUp {
                if !cancelled, !twoMoved, t - twoStartTime < twoFingerTapDuration { rightClick(at: twoTapPoint) }
                mode = .idle
            }
        case .pinching:
            postGesture(hidType: 8, value: 0, phase: 4)
            if rotating { postGesture(hidType: 5, value: 0, phase: 4) }
            mode = allUp ? .idle : .swallow
        case .multi, .swallow:
            if allUp { mode = .idle }
        case .idle:
            break
        }
    }

    // MARK: - 诊断

    /// 关键决策的日志出口（每个手势几行，不是每个触点一行）
    var log: ((String) -> Void)?
    private var lastHitTrail = "-"

    private func note(_ message: @autoclosure () -> String) {
        guard trace == nil, let log else { return }
        log("触控：" + message())
    }

    private var modeName: String {
        switch mode {
        case .idle: return "空闲"
        case .pending: return "点按待定"
        case .longPressed: return "已长按"
        case .dragging: return "拖拽中"
        case .scrolling(let id): return id == nil ? "双指滚动中" : "单指滚动中"
        case .twoPending: return "双指待定"
        case .pinching: return "缩放中"
        case .multi: return "多指"
        case .swallow: return "等待抬起"
        }
    }

    // MARK: - 长按

    private func scheduleLongPress() {
        let work = DispatchWorkItem { [weak self] in
            guard let self, case .pending = self.mode, self.fingers.count == 1, let f = self.fingers.values.first else { return }
            self.mode = .longPressed
            self.feedback(Feedback(kind: .longPress, x: Double(f.norm.x), y: Double(f.norm.y)))
            // 继续按着不动：直接弹右键菜单，不必等抬手
            let menu = DispatchWorkItem { [weak self] in
                guard let self, case .longPressed = self.mode, self.fingers.count == 1, let f = self.fingers.values.first else { return }
                self.note("长按不动 → 右键菜单")
                self.feedback(Feedback(kind: .rightClick, x: Double(f.norm.x), y: Double(f.norm.y)))
                self.rightClick(at: f.start)
                self.mode = .swallow
            }
            self.contextMenuWork = menu
            self.queue.asyncAfter(deadline: .now() + self.contextMenuDelay - self.longPressDelay, execute: menu)
        }
        longPressWork = work
        queue.asyncAfter(deadline: .now() + longPressDelay, execute: work)
    }

    private func cancelLongPress() {
        longPressWork?.cancel()
        longPressWork = nil
        contextMenuWork?.cancel()
        contextMenuWork = nil
    }

    // MARK: - 点击与拖拽

    private func tap(at p: CGPoint) {
        let t = now()
        if t - lastTapTime < multiTapInterval, dist(p, lastTapPoint) < multiTapDistance { tapCount += 1 } else { tapCount = 1 }
        lastTapTime = t
        // 连点时钉在第一次的位置，避免手指微小偏移导致双击失败
        let target = tapCount > 1 ? lastTapPoint : p
        lastTapPoint = target
        let clicks = Int64(tapCount)
        postMouse(.mouseMoved, target)
        postMouse(.leftMouseDown, target, clicks: clicks)
        if trace != nil {
            postMouse(.leftMouseUp, target, clicks: clicks)
        } else {
            queue.asyncAfter(deadline: .now() + clickHold) { [weak self] in self?.postMouse(.leftMouseUp, target, clicks: clicks) }
        }
    }

    private func rightClick(at p: CGPoint) {
        postMouse(.mouseMoved, p)
        postMouse(.rightMouseDown, p, button: .right)
        postMouse(.rightMouseUp, p, button: .right)
    }

    private func beginDrag(_ id: UInt8, _ f: Finger) {
        postMouse(.mouseMoved, f.start)
        postMouse(.leftMouseDown, f.start)
        postMouse(.leftMouseDragged, f.pos)
        mode = .dragging(id)
    }

    // MARK: - 滚动

    private func beginScroll(at origin: CGPoint, from current: CGPoint) {
        postMouse(.mouseMoved, origin)
        scrollStarted = false
        scrollResidual = .zero
        scrollSamples.removeAll(keepingCapacity: true)
        lastScrollPoint = current
    }

    private func scroll(by d: CGPoint, _ t: Double) {
        guard d.x != 0 || d.y != 0 else { return }
        scrollSamples.append((t, d))
        if scrollSamples.count > 24 { scrollSamples.removeFirst() }
        postScroll(dx: Double(d.x), dy: Double(d.y), phase: scrollStarted ? 2 : 1, momentum: 0)
        scrollStarted = true
    }

    private func endScroll(_ t: Double, cancelled: Bool) {
        guard scrollStarted else { return }
        postScroll(dx: 0, dy: 0, phase: 4, momentum: 0)
        scrollStarted = false
        guard !cancelled else { return }
        // 取最后 90ms 的平均速度作为惯性初速
        let recent = scrollSamples.filter { t - $0.t < 0.09 }
        guard let first = recent.first, recent.count >= 2 else { return }
        let span = max(0.016, t - first.t)
        let v = CGPoint(x: recent.reduce(0) { $0 + $1.d.x } / CGFloat(span), y: recent.reduce(0) { $0 + $1.d.y } / CGFloat(span))
        guard hypot(v.x, v.y) > 120 else { return }
        startMomentum(v)
    }

    private func startMomentum(_ v: CGPoint) {
        momentumVelocity = v
        var first = true
        var last = now()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(8), repeating: .milliseconds(8), leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let t = self.now()
            let dt = min(0.05, t - last)
            last = t
            // 指数衰减：每毫秒乘 0.997，一次快速甩动大约滑行一秒半
            let decay = CGFloat(pow(0.997, dt * 1000))
            self.momentumVelocity.x *= decay
            self.momentumVelocity.y *= decay
            if hypot(self.momentumVelocity.x, self.momentumVelocity.y) < 36 {
                self.postScroll(dx: 0, dy: 0, phase: 0, momentum: 3)
                self.momentumTimer?.cancel()
                self.momentumTimer = nil
                return
            }
            self.postScroll(dx: Double(self.momentumVelocity.x) * dt, dy: Double(self.momentumVelocity.y) * dt, phase: 0, momentum: first ? 1 : 2)
            first = false
        }
        momentumTimer = timer
        timer.resume()
    }

    /// 返回之前是否正在惯性滚动
    @discardableResult
    private func stopMomentum() -> Bool {
        guard let timer = momentumTimer else { return false }
        timer.cancel()
        momentumTimer = nil
        postScroll(dx: 0, dy: 0, phase: 0, momentum: 3)
        return true
    }

    /// 内容跟手：手指向下，内容向下。
    private func postScroll(dx: Double, dy: Double, phase: Int64, momentum: Int64) {
        scrollResidual.x += CGFloat(dx)
        scrollResidual.y += CGFloat(dy)
        let ix = Int32(scrollResidual.x.rounded(.towardZero)), iy = Int32(scrollResidual.y.rounded(.towardZero))
        scrollResidual.x -= CGFloat(ix)
        scrollResidual.y -= CGFloat(iy)
        // 不足一个像素的位移先攒着，不发空事件（阶段切换的事件除外）
        if ix == 0, iy == 0, (phase == 2 || momentum == 2) { return }
        if let trace { trace("scroll dx=\(ix) dy=\(iy) phase=\(phase) momentum=\(momentum)"); return }
        guard let e = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2, wheel1: iy, wheel2: ix, wheel3: 0) else { return }
        e.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        e.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: Double(iy) / 10)
        e.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: Double(ix) / 10)
        e.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
        e.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
        TouchCursor.tag(e)
        e.post(tap: .cghidEventTap)
    }

    // MARK: - 缩放与旋转

    private func beginPinch(at c: CGPoint, distance: CGFloat, angle: CGFloat, rotating: Bool) {
        postMouse(.mouseMoved, c)
        mode = .pinching
        twoPrevDistance = distance
        twoPrevAngle = angle
        self.rotating = rotating
        postGesture(hidType: 8, value: 0, phase: 1)
        if rotating { postGesture(hidType: 5, value: 0, phase: 1) }
    }

    /// 合成触控板手势事件。hidType：8＝缩放，5＝旋转；phase：1 开始、2 变化、4 结束。
    private func postGesture(hidType: Int64, value: Double, phase: Int64) {
        if let trace { trace(String(format: "%@ value=%.3f phase=%d", hidType == 8 ? "magnify" : "rotate", value, phase)); return }
        guard let e = CGEvent(source: nil) else { return }
        e.type = CGEventType(rawValue: 29) ?? .null
        e.setIntegerValueField(CGEventField(rawValue: 110)!, value: hidType)
        e.setIntegerValueField(CGEventField(rawValue: 132)!, value: phase)
        e.setDoubleValueField(CGEventField(rawValue: hidType == 5 ? 114 : 113)!, value: value)
        e.post(tap: .cgSessionEventTap)
    }

    // MARK: - 多指滑动

    private typealias CoreDockSend = @convention(c) (CFString, UnsafeMutableRawPointer?) -> Void
    private static let coreDockSend: CoreDockSend? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CoreDockSendNotification") else { return nil }
        return unsafeBitCast(sym, to: CoreDockSend.self)
    }()

    private func performSwipe(dx: CGFloat, dy: CGFloat, fingers: Int) {
        if let trace {
            trace("swipe \(fingers) 指 " + (abs(dx) > abs(dy) ? (dx < 0 ? "左→下一个桌面" : "右→上一个桌面") : (dy < 0 ? "上→调度中心" : "下→应用窗口")))
            return
        }
        if abs(dx) > abs(dy) {
            // 内容跟手：向左滑，露出右边的桌面
            postKey(dx < 0 ? 124 : 123, flags: .maskControl)
        } else if dy < 0 {
            Self.coreDockSend?("com.apple.expose.awake" as CFString, nil)
        } else {
            Self.coreDockSend?("com.apple.expose.front.awake" as CFString, nil)
        }
    }

    private func postKey(_ code: CGKeyCode, flags: CGEventFlags) {
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { continue }
            e.flags = flags
            e.post(tap: .cghidEventTap)
        }
    }

    // MARK: - 笔与指针

    private func handlePointer(_ c: TouchContact, _ p: CGPoint) {
        let isPencil = c.kind == .pencil
        lastPointerActivity = now()
        if trace == nil { TouchCursor.show() }
        switch c.phase {
        case .began:
            // 笔落下时终止正在进行的手指手势
            if !fingers.isEmpty { abortFingerGesture() }
            stopMomentum()
            bounds = currentBounds()
            pointerDown = true
            pointerIsPencil = isPencil
            let t = now()
            if t - lastPointerDownTime < multiTapInterval, dist(p, lastPointerDownPoint) < 12 { pointerClicks += 1 } else { pointerClicks = 1 }
            lastPointerDownTime = t
            lastPointerDownPoint = p
            if isPencil { postProximity(enter: true, at: p) }
            postMouse(.mouseMoved, p)
            postMouse(.leftMouseDown, p, clicks: pointerClicks, pen: isPencil ? c : nil)
        case .moved, .stationary:
            guard pointerDown else { return }
            postMouse(.leftMouseDragged, p, clicks: pointerClicks, pen: isPencil ? c : nil)
        case .ended, .cancelled:
            guard pointerDown else { return }
            pointerDown = false
            var lifted = c
            lifted.pressure = 0
            postMouse(.leftMouseUp, p, clicks: pointerClicks, pen: isPencil ? lifted : nil)
        }
    }

    private func handleHover(_ c: TouchContact, _ p: CGPoint) {
        guard !pointerDown, fingers.isEmpty else { return }
        if trace == nil { TouchCursor.show() }
        if c.phase == .began || c.phase == .moved { postMouse(.mouseMoved, p) }
    }

    private func abortFingerGesture() {
        cancelLongPress()
        switch mode {
        case .dragging(let id): postMouse(.leftMouseUp, fingers[id]?.pos ?? cursorPoint())
        case .scrolling: postScroll(dx: 0, dy: 0, phase: 4, momentum: 0); scrollStarted = false
        case .pinching: postGesture(hidType: 8, value: 0, phase: 4)
        default: break
        }
        ignoredFingers.formUnion(fingers.keys)
        fingers.removeAll()
        order.removeAll()
        mode = .idle
    }

    private func postProximity(enter: Bool, at p: CGPoint) {
        if let trace { trace("penProximity enter=\(enter)"); return }
        guard let e = CGEvent(source: source) else { return }
        e.type = .tabletProximity
        e.location = p
        e.setIntegerValueField(.tabletProximityEventEnterProximity, value: enter ? 1 : 0)
        e.setIntegerValueField(.tabletProximityEventDeviceID, value: 1)
        e.setIntegerValueField(.tabletProximityEventPointerType, value: 1)
        e.setIntegerValueField(.tabletProximityEventCapabilityMask, value: 0x0400 | 0x0080 | 0x0001)
        e.post(tap: .cghidEventTap)
    }

    // MARK: - 事件投递

    private func postMouse(_ type: CGEventType, _ p: CGPoint, button: CGMouseButton = .left, clicks: Int64 = 1, pen: TouchContact? = nil) {
        if let trace {
            let names: [CGEventType: String] = [.mouseMoved: "move", .leftMouseDown: "leftDown", .leftMouseUp: "leftUp", .leftMouseDragged: "leftDrag",
                                                .rightMouseDown: "rightDown", .rightMouseUp: "rightUp"]
            trace(String(format: "%@ (%.0f,%.0f) clicks=%d%@", names[type] ?? "mouse\(type.rawValue)", p.x, p.y, clicks,
                         pen.map { String(format: " pressure=%.2f", $0.pressure) } ?? ""))
            return
        }
        guard let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: button) else { return }
        if type != .mouseMoved { e.setIntegerValueField(.mouseEventClickState, value: clicks) }
        if let pen {
            let pressure = Double(max(0, min(1, pen.pressure)))
            // 高度角 90° 为垂直。倾斜量映射到 -1…1
            let tilt = Double(cos(pen.altitude))
            e.setIntegerValueField(.mouseEventSubtype, value: 1)
            e.setDoubleValueField(.mouseEventPressure, value: pressure)
            e.setDoubleValueField(.tabletEventPointPressure, value: pressure)
            e.setDoubleValueField(.tabletEventTiltX, value: tilt * Double(cos(pen.azimuth)))
            e.setDoubleValueField(.tabletEventTiltY, value: -tilt * Double(sin(pen.azimuth)))
            e.setIntegerValueField(.tabletEventDeviceID, value: 1)
        }
        TouchCursor.tag(e)
        e.post(tap: .cghidEventTap)
    }

    private func cursorPoint() -> CGPoint { CGEvent(source: nil)?.location ?? .zero }

    // MARK: - 命中测试

    /// 触点下方是不是「一按就该跟手拖」的东西：滑块、滚动条、分隔条、标题栏、工具栏等。
    /// 其余一律按滚动处理（随航的规则：单指按下马上滑是滚动，按住再移动才是拖动）。
    private func dragsDirectly(at p: CGPoint) -> Bool {
        if let scrollableOverride { return !scrollableOverride(p) }
        guard AXIsProcessTrusted() else { lastHitTrail = "没有辅助功能权限"; return false }
        var hit: AXUIElement?
        let status = AXUIElementCopyElementAtPosition(systemWide, Float(p.x), Float(p.y), &hit)
        guard status == .success, var element = hit else { lastHitTrail = "命中测试失败 \(status.rawValue)"; return false }
        var trail: [String] = []
        defer { lastHitTrail = trail.joined(separator: "›") }
        for depth in 0..<16 {
            var roleValue: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleValue)
            let role = roleValue as? String
            trail.append(role?.replacingOccurrences(of: "AX", with: "") ?? "?")
            switch role {
            case "AXScrollBar", "AXSlider", "AXSplitter", "AXValueIndicator", "AXHandle", "AXGrowArea",
                 "AXIncrementor", "AXColorWell", "AXToolbar", "AXMenu", "AXMenuItem", "AXMenuBar", "AXMenuBarItem", "AXDockItem":
                return true
            case "AXScrollArea", "AXWebArea":
                return false
            case "AXWindow", "AXSheet", "AXDrawer":
                // 直接点在窗口外框上，或点在紧贴外框的标题文字上：当作拖动窗口
                return depth <= 1
            case "AXApplication":
                return false
            default:
                break
            }
            var parent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &parent) == .success,
                  let next = parent, CFGetTypeID(next) == AXUIElementGetTypeID() else { return false }
            element = next as! AXUIElement
        }
        return false
    }

    // MARK: - 几何

    private func now() -> Double { Double(monotonicNs()) / 1e9 }
    private func dist(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }
    private func mid(_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2) }
    private func angle(_ a: CGPoint, _ b: CGPoint) -> CGFloat { atan2(b.y - a.y, b.x - a.x) * 180 / .pi }
    private func angleDelta(_ a: CGFloat, _ b: CGFloat) -> CGFloat {
        var d = a - b
        while d > 180 { d -= 360 }
        while d < -180 { d += 360 }
        return d
    }

    private func centroid() -> CGPoint {
        guard !fingers.isEmpty else { return .zero }
        let n = CGFloat(fingers.count)
        return CGPoint(x: fingers.values.reduce(0) { $0 + $1.pos.x } / n, y: fingers.values.reduce(0) { $0 + $1.pos.y } / n)
    }

    private func twoCentroid() -> CGPoint {
        guard order.count >= 2, let a = fingers[order[0]], let b = fingers[order[1]] else { return centroid() }
        return mid(a.pos, b.pos)
    }
}
