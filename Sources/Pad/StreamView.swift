import UIKit
import AVFoundation

/// 显示画面并采集触控的视图。手指、Apple Pencil（含压感、倾斜、悬停）和外接指针都会上报。
final class StreamView: UIView {
    /// 显示画面的层
    let displayLayer = AVSampleBufferDisplayLayer()

    var onTouches: ((TouchPacket) -> Void)?

    /// 手指拖动时用系统预测的位置（往前看约一帧）代替当前位置发给 Mac
    var predictTouches = true

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

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) { send(touches, with: event, phase: .began) }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) { send(touches, with: event, phase: .moved) }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { send(touches, with: event, phase: .ended) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { send(touches, with: event, phase: .cancelled) }

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
