import UIKit

/// 看不见的输入视图：成为第一响应者时系统弹出屏幕键盘，敲下的内容转给 Mac。
final class KeyboardProxy: UIView, UIKeyInput {
    var onText: ((String) -> Void)?
    var onKey: ((UInt16) -> Void)?
    var onPresses: ((Set<UIPress>, Bool) -> Bool)?

    override var canBecomeFirstResponder: Bool { true }
    var hasText: Bool { true }
    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var spellCheckingType: UITextSpellCheckingType = .no
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no
    var smartInsertDeleteType: UITextSmartInsertDeleteType = .no

    func insertText(_ text: String) {
        // 回车和制表按真实按键发，应用才会当成「确认」而不是插入字符
        if text == "\n" { onKey?(0x28) } else if text == "\t" { onKey?(0x2B) } else { onText?(text) }
    }

    func deleteBackward() { onKey?(0x2A) }

    // 外接键盘的按键仍按键码转发，不走文字输入，避免重复
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if onPresses?(presses, true) != true { super.pressesBegan(presses, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if onPresses?(presses, false) != true { super.pressesEnded(presses, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if onPresses?(presses, false) != true { super.pressesCancelled(presses, with: event) }
    }
}

final class StreamViewController: UIViewController {
    private let keyboardProxy = KeyboardProxy(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
    let streamView = StreamView()
    private let cover = UIView()
    weak var model: PadModel?

    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    // 屏幕边缘的滑动先交给 Mac 画面，系统手势需要滑两次才触发
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { .all }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .all }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        streamView.frame = view.bounds
        streamView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(streamView)

        cover.frame = view.bounds
        cover.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        cover.backgroundColor = .black
        cover.alpha = 0
        cover.isUserInteractionEnabled = false
        view.addSubview(cover)

        keyboardProxy.alpha = 0
        keyboardProxy.onText = { [weak self] text in self?.model?.sendText(text) }
        keyboardProxy.onKey = { [weak self] usage in
            self?.model?.sendKey(usage: usage, down: true)
            self?.model?.sendKey(usage: usage, down: false)
        }
        keyboardProxy.onPresses = { [weak self] presses, down in self?.forward(presses, down: down) ?? false }
        view.addSubview(keyboardProxy)
        NotificationCenter.default.addObserver(forName: UIResponder.keyboardDidHideNotification, object: nil, queue: .main) { [weak self] _ in
            // 用户用键盘上的收起键关掉了键盘
            guard let self, !self.keyboardProxy.isFirstResponder else { return }
            self.model?.keyboardDidHide()
        }

        // 外接触控板或鼠标的滚动（只认滚动输入，不抢手指的触摸）
        let scroll = UIPanGestureRecognizer(target: self, action: #selector(scrolled(_:)))
        scroll.allowedScrollTypesMask = .all
        scroll.allowedTouchTypes = []
        streamView.addGestureRecognizer(scroll)
    }

    private var lastScrollTranslation = CGPoint.zero

    @objc private func scrolled(_ g: UIPanGestureRecognizer) {
        let t = g.translation(in: streamView)
        switch g.state {
        case .began:
            lastScrollTranslation = t
            model?.sendScroll(dx: t.x, dy: t.y, phase: 0)
        case .changed:
            model?.sendScroll(dx: t.x - lastScrollTranslation.x, dy: t.y - lastScrollTranslation.y, phase: 1)
            lastScrollTranslation = t
        default:
            model?.sendScroll(dx: 0, dy: 0, phase: 2)
        }
    }

    // MARK: 屏幕键盘

    func setKeyboard(visible: Bool) {
        if visible {
            keyboardProxy.becomeFirstResponder()
        } else if keyboardProxy.isFirstResponder {
            keyboardProxy.resignFirstResponder()
            becomeFirstResponder()
        }
    }

    // MARK: 外接键盘

    override var canBecomeFirstResponder: Bool { true }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
    }

    private func forward(_ presses: Set<UIPress>, down: Bool) -> Bool {
        guard let model, model.connected else { return false }
        var handled = false
        for press in presses {
            guard let key = press.key else { continue }
            model.sendKey(usage: UInt16(key.keyCode.rawValue), down: down)
            handled = true
        }
        return handled
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if !forward(presses, down: true) { super.pressesBegan(presses, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if !forward(presses, down: false) { super.pressesEnded(presses, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if !forward(presses, down: false) { super.pressesCancelled(presses, with: event) }
    }

    /// 当前界面方向下，画面区域的物理像素尺寸
    var viewportPixels: Viewport { pixels(for: view.bounds.size) }

    private func pixels(for size: CGSize) -> Viewport {
        let screen = view.window?.screen ?? UIScreen.main
        let scale = screen.nativeScale
        // 向偶数取整，编码器要求偶数边长
        func even(_ v: CGFloat) -> Int { Int((v * scale / 2).rounded()) * 2 }
        return Viewport(width: even(size.width), height: even(size.height))
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        guard size != view.bounds.size else { return }
        model?.viewportWillChange(to: pixels(for: size))
    }

    /// 旋转时用黑幕盖住旧方向的画面，新方向的第一帧到达后再揭开
    func setCover(visible: Bool, animated: Bool) {
        let target: CGFloat = visible ? 1 : 0
        guard cover.alpha != target else { return }
        if animated {
            UIView.animate(withDuration: visible ? 0.12 : 0.22, delay: 0, options: [.beginFromCurrentState, .curveEaseOut]) {
                self.cover.alpha = target
            }
        } else {
            cover.alpha = target
        }
    }
}
