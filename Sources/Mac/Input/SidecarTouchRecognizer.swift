import AppKit

/// 接收随航的原生触点。
///
/// macOS 27 的随航触控不走事件流，也不经过任何事件监听，只交给手指下那个窗口上挂的手势识别器
/// （Apple TN3212；Blender 的随航触控也是这么接的）。这个识别器只收直接触控，不认鼠标，
/// 每次触点变化都把当前所有手指交给 `onTouches`，坐标归一化、原点在视图左上角。
final class SidecarTouchRecognizer: NSGestureRecognizer {
    struct Contact {
        var id: UInt8
        var phase: TouchPhase
        var x: CGFloat
        var y: CGFloat
    }

    var onTouches: (([Contact]) -> Void)?

    /// NSTouch.identity 在同一根手指的各次事件里相等（isEqual），按它分配稳定的小编号
    private var ids: [(identity: NSObject, id: UInt8)] = []
    private var nextID: UInt8 = 0
    private var lastCentroid = NSPoint.zero

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        allowedTouchTypes = .direct
        delaysPrimaryMouseButtonEvents = false
        delaysSecondaryMouseButtonEvents = false
    }

    required init?(coder: NSCoder) { fatalError() }

    override func touchesBegan(with event: NSEvent) { forward(event) }
    override func touchesMoved(with event: NSEvent) { forward(event) }
    override func touchesEnded(with event: NSEvent) { forward(event) }
    override func touchesCancelled(with event: NSEvent) { forward(event, cancelled: true) }

    override func reset() {
        super.reset()
        ids.removeAll()
    }

    /// macOS 27 SDK 要求自定义识别器实现它，否则返回零点并报错
    override func location(in view: NSView?) -> NSPoint {
        guard let own = self.view else { return lastCentroid }
        return view.map { own.convert(lastCentroid, to: $0) } ?? own.convert(lastCentroid, to: nil)
    }

    private func forward(_ event: NSEvent, cancelled: Bool = false) {
        guard let view else { return }
        let size = view.bounds.size
        guard size.width > 0, size.height > 0 else { return }
        var contacts: [Contact] = []
        var touching = 0
        var sum = NSPoint.zero
        for touch in event.touches(matching: .any, in: view) where touch.type == .direct {
            let phase: TouchPhase
            switch touch.phase {
            case .began: phase = .began
            case .moved: phase = .moved
            case .stationary: phase = .stationary
            case .ended: phase = .ended
            case .cancelled: phase = .cancelled
            default: continue
            }
            let identity = touch.identity as! NSObject
            let id: UInt8
            if let found = ids.first(where: { $0.identity.isEqual(identity) }) {
                id = found.id
            } else {
                id = nextID
                nextID &+= 1
                ids.append((identity, id))
            }
            let p = touch.location(in: view)
            let ended = phase == .ended || phase == .cancelled
            if ended {
                ids.removeAll { $0.identity.isEqual(identity) }
            } else {
                touching += 1
                sum.x += p.x; sum.y += p.y
            }
            contacts.append(Contact(id: id, phase: cancelled && !ended ? .cancelled : phase,
                                    x: min(max(p.x / size.width, 0), 1),
                                    // AppKit 视图坐标 y 朝上，换成左上角原点
                                    y: min(max(1 - p.y / size.height, 0), 1)))
        }
        if touching > 0 { lastCentroid = NSPoint(x: sum.x / CGFloat(touching), y: sum.y / CGFloat(touching)) }
        if !contacts.isEmpty { onTouches?(contacts) }
        if cancelled {
            ids.removeAll()
            state = .cancelled
        } else if touching == 0 {
            state = state == .possible ? .failed : .ended
        } else {
            state = state == .possible ? .began : .changed
        }
    }
}
