import UIKit
import AVFoundation

/// 显示画面并采集触控的视图。手指、Apple Pencil（含压感、倾斜、悬停）和外接指针都会上报。
final class StreamView: UIView {
    /// 显示画面的层
    let displayLayer = AVSampleBufferDisplayLayer()

    var onTouches: ((TouchPacket) -> Void)?

    /// 手指拖动时用系统预测的位置（往前看约一帧）代替当前位置发给 Mac
    var predictTouches = true

    /// 滚动先行：单指竖向滑动时，iPad 先按手指把画面挪过去，Mac 的新画面到了再无缝对上（藏住网络延迟）
    var scrollAhead = true

    private var ids: [ObjectIdentifier: UInt8] = [:]
    private static let hoverID: UInt8 = 250

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        isExclusiveTouch = true
        backgroundColor = .black
        layer.addSublayer(displayLayer)
        let hover = UIHoverGestureRecognizer(target: self, action: #selector(hovered(_:)))
        addGestureRecognizer(hover)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer.bounds = CGRect(origin: .zero, size: bounds.size)
        displayLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        CATransaction.commit()
    }

    // MARK: 触控

    private func id(for touch: UITouch, allocate: Bool) -> UInt8? {
        let key = ObjectIdentifier(touch)
        if let existing = ids[key] { return existing }
        guard allocate else { return nil }
        let used = Set(ids.values)
        guard let free = (0..<UInt8(32)).first(where: { !used.contains($0) }) else { return nil }
        ids[key] = free
        return free
    }

    private func contact(_ touch: UITouch, id: UInt8, phase: TouchPhase, at location: CGPoint? = nil) -> TouchContact {
        let p = location ?? touch.preciseLocation(in: self)
        let w = max(1, bounds.width), h = max(1, bounds.height)
        let kind: TouchKind
        switch touch.type {
        case .pencil: kind = .pencil
        case .indirectPointer: kind = .pointer
        default: kind = .finger
        }
        let pressure: CGFloat = touch.maximumPossibleForce > 0 ? touch.force / touch.maximumPossibleForce : (phase == .ended ? 0 : 1)
        return TouchContact(id: id, phase: phase, kind: kind,
                            x: Float(min(1, max(0, p.x / w))), y: Float(min(1, max(0, p.y / h))),
                            pressure: Float(pressure),
                            altitude: Float(kind == .pencil ? touch.altitudeAngle : .pi / 2),
                            azimuth: Float(kind == .pencil ? touch.azimuthAngle(in: self) : 0),
                            radius: Float(touch.majorRadius))
    }

    private func send(_ touches: Set<UITouch>, with event: UIEvent?, phase: TouchPhase) {
        var contacts: [TouchContact] = []
        var latest: TimeInterval = 0
        for touch in touches {
            guard let id = id(for: touch, allocate: phase == .began) else { continue }
            if phase == .moved, touch.type == .pencil, let coalesced = event?.coalescedTouches(for: touch), coalesced.count > 1 {
                // 笔迹要用上全部采样点，线条才顺
                for sample in coalesced.dropLast() {
                    onTouches?(TouchPacket(timestamp: UInt64(sample.timestamp * 1e9), contacts: [contact(sample, id: id, phase: .moved)]))
                }
            }
            var location = touch.preciseLocation(in: self)
            if phase == .moved, predictTouches, touch.type == .direct,
               let predicted = event?.predictedTouches(for: touch)?.last {
                location = predicted.preciseLocation(in: self)
            }
            contacts.append(contact(touch, id: id, phase: phase, at: location))
            latest = max(latest, touch.timestamp)
            if phase == .ended || phase == .cancelled { ids[ObjectIdentifier(touch)] = nil }
        }
        guard !contacts.isEmpty else { return }
        onTouches?(TouchPacket(timestamp: UInt64(latest * 1e9), contacts: contacts))
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) { send(touches, with: event, phase: .began); ahead(event, phase: .began) }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) { send(touches, with: event, phase: .moved); ahead(event, phase: .moved) }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { send(touches, with: event, phase: .ended); ahead(event, phase: .ended) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { send(touches, with: event, phase: .cancelled); ahead(event, phase: .cancelled) }

    // MARK: 滚动先行

    private struct Ahead {
        var history: [(ts: UInt64, y: CGFloat)] = []
        var startX: CGFloat = 0, startY: CGFloat = 0
        var startTs: UInt64 = 0
        var lastMoveTs: UInt64 = 0
        var engaged = false
        var disqualified = false
        var liftTs: UInt64?
    }
    private var aheadState: Ahead?
    /// 最近一帧画面已经反映到的触控时间戳（iPad 时钟，纳秒）
    private var shownTouchTs: UInt64 = 0
    private var lastTouchTsFrame: UInt64 = 0
    private var resetWork: DispatchWorkItem?

    private func ahead(_ event: UIEvent?, phase: TouchPhase) {
        guard scrollAhead else { return }
        let fingers = event?.allTouches?.filter { $0.type == .direct && $0.phase != .ended && $0.phase != .cancelled } ?? []
        let now = monotonicNs()
        switch phase {
        case .began:
            // 只管单指；新手势开始时上一次的偏移如果还在，就地收掉
            setOffset(0)
            guard fingers.count == 1, let t = fingers.first else { aheadState = nil; return }
            let p = t.preciseLocation(in: self)
            var a = Ahead()
            a.startX = p.x; a.startY = p.y
            a.startTs = UInt64(t.timestamp * 1e9)
            a.lastMoveTs = a.startTs
            a.history = [(a.startTs, p.y)]
            // 上下边缘起手是系统 / Mac 的边缘手势，不先行
            a.disqualified = p.y < 30 || p.y > bounds.height - 30
            aheadState = a
        case .moved:
            guard var a = aheadState, !a.disqualified else { return }
            guard fingers.count == 1, let t = fingers.first else { a.disqualified = true; aheadState = a; setOffset(0); return }
            let p = t.preciseLocation(in: self)
            let ts = UInt64(t.timestamp * 1e9)
            let dx = abs(p.x - a.startX), dy = abs(p.y - a.startY)
            if !a.engaged {
                // 先按住不动再拖：多半是选文字 / 拖窗口，不是滚动
                if ts - a.startTs > 350_000_000, dy < 6 { a.disqualified = true; aheadState = a; return }
                // 最近 1 秒内要有带触控时间戳的画面（UDP），才知道画面落后多少
                if dy > 12 {
                    if dy > dx * 2.5, now - lastTouchTsFrame < 1_000_000_000 { a.engaged = true } else { a.disqualified = true; aheadState = a; return }
                }
            }
            a.history.append((ts, p.y))
            if a.history.count > 240 { a.history.removeFirst(a.history.count - 240) }
            a.lastMoveTs = ts
            aheadState = a
            if a.engaged { applyAhead() }
        case .ended, .cancelled:
            guard var a = aheadState else { return }
            if !a.engaged { aheadState = nil; return }
            a.liftTs = a.lastMoveTs
            aheadState = a
            applyAhead()
            // 兜底：画面迟迟没追上（比如这次滑动其实没滚动任何东西），半秒后收回
            resetWork?.cancel()
            let w = DispatchWorkItem { [weak self] in self?.aheadState = nil; self?.setOffset(0, animated: true) }
            resetWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: w)
        default:
            break
        }
    }

    /// 刚上屏的画面反映到了哪个触控（主线程）
    func frameShown(touchTs: UInt64) {
        guard touchTs > 0 else { return }
        lastTouchTsFrame = monotonicNs()
        shownTouchTs = max(shownTouchTs, touchTs)
        guard let a = aheadState, a.engaged else { return }
        if let lift = a.liftTs, shownTouchTs >= lift {
            aheadState = nil
            resetWork?.cancel()
            setOffset(0)
            return
        }
        applyAhead()
    }

    private func applyAhead() {
        guard let a = aheadState, a.engaged, let last = a.history.last else { return }
        // 画面已经反映到的手指位置：在历史里找 shownTouchTs 那一刻（早于手势开始就算起点）
        var yShown = a.startY
        for h in a.history.reversed() where h.ts <= shownTouchTs { yShown = h.y; break }
        setOffset(min(160, max(-160, last.y - yShown)))
    }

    private func setOffset(_ y: CGFloat, animated: Bool = false) {
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        if animated { CATransaction.setAnimationDuration(0.12) }
        displayLayer.setAffineTransform(y == 0 ? .identity : CGAffineTransform(translationX: 0, y: y))
        CATransaction.commit()
    }

    @objc private func hovered(_ g: UIHoverGestureRecognizer) {
        let phase: TouchPhase
        switch g.state {
        case .began: phase = .began
        case .changed: phase = .moved
        default: phase = .ended
        }
        let p = g.location(in: self)
        let w = max(1, bounds.width), h = max(1, bounds.height)
        let c = TouchContact(id: Self.hoverID, phase: phase, kind: .hover,
                             x: Float(min(1, max(0, p.x / w))), y: Float(min(1, max(0, p.y / h))),
                             pressure: 0, altitude: .pi / 2, azimuth: 0, radius: 0)
        onTouches?(TouchPacket(timestamp: monotonicNs(), contacts: [c]))
    }

    /// 连接断开时丢弃所有进行中的触点
    func resetTouches() { ids.removeAll() }

    // MARK: 触控反馈

    /// 在指定归一化位置播放一圈涟漪，提示长按或右键已被识别
    func showFeedback(_ feedback: Feedback) {
        let center = CGPoint(x: feedback.x * bounds.width, y: feedback.y * bounds.height)
        let ring = CAShapeLayer()
        let radius: CGFloat = 26
        ring.path = UIBezierPath(ovalIn: CGRect(x: -radius, y: -radius, width: radius * 2, height: radius * 2)).cgPath
        ring.position = center
        ring.fillColor = UIColor.white.withAlphaComponent(feedback.kind == .dragStart ? 0.10 : 0.16).cgColor
        ring.strokeColor = UIColor.white.withAlphaComponent(0.55).cgColor
        ring.lineWidth = 1.5
        layer.addSublayer(ring)

        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = feedback.kind == .longPress ? 0.35 : 0.6
        grow.toValue = feedback.kind == .longPress ? 1.0 : 1.5
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [grow, fade]
        group.duration = feedback.kind == .longPress ? 0.45 : 0.32
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        group.isRemovedOnCompletion = false
        group.fillMode = .forwards
        CATransaction.begin()
        CATransaction.setCompletionBlock { ring.removeFromSuperlayer() }
        ring.add(group, forKey: "ripple")
        CATransaction.commit()

        if feedback.kind == .longPress {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        }
    }
}
