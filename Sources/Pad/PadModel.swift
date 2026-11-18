import SwiftUI
import UIKit
import GameController

/// iPad 端的状态中枢：网络事件进来，画面和触控出去。
final class PadModel: ObservableObject {
    @Published private(set) var connected = false
    @Published private(set) var showingStream = false
    @Published private(set) var hostName = ""
    /// 连接刚断、正在保留画面等对端重连
    @Published private(set) var reconnecting = false
    private var graceGeneration = 0

    private let server = PadServer()
    private weak var controller: StreamViewController?
    private var renderer: VideoRenderer?
    private var expected = Viewport(width: 0, height: 0)
    private var started = false

    @Published private(set) var wireless = false
    /// Mac 说的连接方式："wired" / "local" / "remote"
    @Published private(set) var transport = ""
    /// 正在镜像 Mac 主屏（否则是独立的扩展屏）
    @Published private(set) var displayMode = DisplayMode.extend
    private let mesh = MeshLink()
    /// 远程状态说明（等待界面上显示）
    @Published private(set) var remoteStatus = ""

    // MARK: 跟手选项（工具条里可以单独关掉）

    private static func setting(_ key: String) -> Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
    /// 发预测的触控位置
    @Published var touchPredict = PadModel.setting("touchPredict") {
        didSet { UserDefaults.standard.set(touchPredict, forKey: "touchPredict"); controller?.streamView.predictTouches = touchPredict }
    }
    /// 小画面在 iPad 上超分放大
    @Published var superResolution = PadModel.setting("superResolution") {
        didSet { UserDefaults.standard.set(superResolution, forKey: "superResolution"); renderer?.superResolution = superResolution }
    }
    let superResolutionSupported = VideoRenderer.superResolutionSupported

    /// 传 Mac 的声音。关掉时 Mac 连声音采集都停，不占带宽
    @Published var audioEnabled = PadModel.setting("audio") {
        didSet { UserDefaults.standard.set(audioEnabled, forKey: "audio"); applyAudio() }
    }
    private let player = AudioPlayer()
    private let clipboard = PadClipboard()

    /// 这台 iPad 的无线配对密钥，首次启动时生成。只会在有线握手里交给 Mac。
    private let pairingKey: Data = {
        if let saved = UserDefaults.standard.data(forKey: "pairingKey"), saved.count == 32 { return saved }
        let key = Pairing.generateKey()
        UserDefaults.standard.set(key, forKey: "pairingKey")
        return key
    }()
    private let deviceID = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString

    init() {
        server.pairingKey = pairingKey
        server.deviceID = deviceID
        server.serviceName = UIDevice.current.name
        server.onEvent = { [weak self] event in self?.handle(event) }
        mesh.onStatus = { [weak self] s in self?.remoteStatus = s }
        mesh.dial = { [weak self] endpoint in self?.server.dial(endpoint) }
        clipboard.send = { [weak self] p in
            guard let self, self.connected else { return }
            self.server.send(.clipboard, p)
        }
    }

    private func applyAudio() {
        guard connected else { return }
        server.send(.audioEnable, Data([audioEnabled ? 1 : 0]))
        if audioEnabled { player.start() } else { player.stop() }
    }

    func toggleAudio() {
        audioEnabled.toggle()
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    func attach(_ controller: StreamViewController) {
        self.controller = controller
        let renderer = VideoRenderer(layer: controller.streamView.displayLayer)
        renderer.onNeedKeyframe = { [weak self] in self?.requestKeyframe() }
        renderer.onFirstFrame = { [weak self] w, h in
            DispatchQueue.main.async { self?.firstFrameArrived(width: w, height: h) }
        }
        renderer.superResolution = superResolution
        controller.streamView.predictTouches = touchPredict
        self.renderer = renderer
        controller.streamView.onTouches = { [weak self] packet in
            self?.lastTouchNs = monotonicNs()
            guard let self, self.connected else { return }
            self.server.send(.touch, packet.encode())
        }
    }

    func start() {
        guard !started else { return }
        started = true
        server.start()
        mesh.setConnected(connected)
        mesh.start()
    }

    func stop() {
        guard started else { return }
        started = false
        mesh.stop()
        server.stop()
        didDisconnect(final: true)
    }

    // MARK: 网络事件（网络队列）

    private var lastKeyframeRequest: UInt64 = 0

    private func requestKeyframe() {
        // 限流：最多每 250ms 请求一次
        let now = monotonicNs()
        guard now - lastKeyframeRequest > 250_000_000 else { return }
        lastKeyframeRequest = now
        server.send(.keyframeRequest)
    }

    private func handle(_ event: PadServer.Event) {
        switch event {
        case .connected(let wired):
            DispatchQueue.main.async { self.didConnect(wired: wired) }
        case .config(let config):
            DispatchQueue.main.async {
                self.hostName = config.hostName
                self.expected = Viewport(width: config.width, height: config.height)
                self.displayMode = config.mode.flatMap(DisplayMode.init) ?? ((config.mirror ?? false) ? .mirror : .extend)
                self.transport = config.transport ?? ""
                // 有线时 Mac 会给出远程组网参数，记下来，下次隔着两地也能连
                if let m = config.mesh { self.mesh.update(m) }
            }
        case .format(let payload):
            renderer?.setFormat(payload)
        case .video(let header, let data):
            show(header, data)
        case .rtVideo(let frame):
            // UDP 来的关键帧自带参数集
            if let format = frame.format { renderer?.setFormat(format) }
            show(VideoHeader(isKey: frame.isKey, index: frame.index, captureNs: frame.captureNs), frame.data)
        case .rtLoss:
            renderer?.waitForKeyframe()
        case .rtReady:
            break
        case .audio(let payload):
            player.play(payload)
        case .clipboard(let payload):
            DispatchQueue.main.async { self.clipboard.apply(payload) }
        case .textFocus(let focused):
            DispatchQueue.main.async { self.textFocusChanged(focused) }
        case .feedback(let fb):
            DispatchQueue.main.async { self.controller?.streamView.showFeedback(fb) }
        case .disconnected(let final):
            DispatchQueue.main.async { self.didDisconnect(final: final) }
        }
    }

    /// 送显并回执（网络队列）
    private func show(_ header: VideoHeader, _ data: Data) {
        let started = monotonicNs()
        logStats(header, bytes: data.count)
        guard renderer?.enqueue(header, data) == true else { return }
        var ack = Data(capacity: 8)
        ack.appendLE(header.index)
        ack.appendLE(UInt32(min(UInt64(UInt32.max), (monotonicNs() - started) / 1000)))
        server.send(.ack, ack)
    }

    private var statFrames = 0
    private var statBytes = 0
    private var statTime: UInt64 = 0

    /// 每两秒在控制台打印一次收帧与解码显示层的状态（网络队列）
    private func logStats(_ header: VideoHeader, bytes: Int) {
        statFrames += 1
        statBytes += bytes
        let now = monotonicNs()
        if statTime == 0 { statTime = now }
        guard now - statTime > 2_000_000_000, let renderer else { return }
        let r = renderer.layer.sampleBufferRenderer
        print("收帧 \(statFrames) 帧 \(statBytes / 1024)KB，显示层状态 \(r.status.rawValue)，错误 \(r.error?.localizedDescription ?? "无")")
        statFrames = 0
        statBytes = 0
        statTime = now
    }

    // MARK: 主线程

    private func didConnect(wired: Bool) {
        guard let controller else { return }
        connected = true
        wireless = !wired
        mesh.setConnected(true)
        graceGeneration += 1
        reconnecting = false
        // 重连时保留屏幕上的最后一帧，新画面到了直接接上
        renderer?.reset(keepImage: showingStream)
        renderer?.targetWidth = controller.viewportPixels.width
        UIApplication.shared.isIdleTimerDisabled = true
        var hello = makeHello(controller)
        // 密钥只走 USB 线，绝不经无线发送
        if wired { hello.pairingKey = pairingKey.base64EncodedString() }
        server.send(.hello, jsonEncode(hello))
        applyAudio()
    }

    /// - Parameter final: 对端主动结束或应用退到后台。否则先保留画面几秒，等对端从另一条线路重连。
    private func didDisconnect(final: Bool) {
        guard connected || showingStream else { return }
        connected = false
        player.stop()
        heldKeys.removeAll()
        mesh.setConnected(false)
        controller?.streamView.resetTouches()
        resetInputState()
        graceGeneration += 1
        guard !final, showingStream else { endStream(); return }
        reconnecting = true
        let generation = graceGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self, self.graceGeneration == generation, !self.connected else { return }
            self.endStream()
        }
    }

    private func endStream() {
        reconnecting = false
        showingStream = false
        hostName = ""
        UIApplication.shared.isIdleTimerDisabled = false
        controller?.setCover(visible: false, animated: false)
        renderer?.reset()
    }

    // MARK: 工具条：修饰键与屏幕键盘

    /// 已锁定的修饰键（HID 用途码）
    @Published private(set) var latchedModifiers = Set<UInt16>()
    @Published private(set) var keyboardVisible = false

    func toggleModifier(_ usage: UInt16) {
        guard connected else { return }
        if latchedModifiers.remove(usage) != nil {
            sendKey(usage: usage, down: false)
        } else {
            latchedModifiers.insert(usage)
            sendKey(usage: usage, down: true)
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    func setKeyboardVisible(_ visible: Bool) {
        keyboardVisible = visible
        controller?.setKeyboard(visible: visible)
    }

    func keyboardDidHide() { keyboardVisible = false; keyboardAutoShown = false }

    private var lastTouchNs: UInt64 = 0
    /// 屏幕键盘是不是因为点了输入框才自动弹出的（只有这种才自动收起）
    private var keyboardAutoShown = false

    /// 在 Mac 上点到输入框时自动弹出屏幕键盘，离开输入框时收起。
    /// 只认刚点过画面（1.5 秒内）引起的焦点变化；接了外接键盘就不弹。
    private func textFocusChanged(_ focused: Bool) {
        guard connected else { return }
        if focused {
            let recent = monotonicNs() - lastTouchNs < 1_500_000_000
            guard recent, !keyboardVisible, GCKeyboard.coalesced == nil else { return }
            setKeyboardVisible(true)
            keyboardAutoShown = true
        } else if keyboardAutoShown, keyboardVisible {
            setKeyboardVisible(false)
            keyboardAutoShown = false
        }
    }

    /// 切换显示模式（Mac 那边的菜单也会跟着变）
    func setDisplayMode(_ m: DisplayMode) {
        guard connected, m != displayMode else { return }
        server.send(.mode, Data([UInt8(m.rawValue)]))
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    func sendText(_ text: String) {
        guard connected else { return }
        server.send(.text, Data(text.utf8))
    }

    /// 连接中断：Mac 那边会自行松开所有键，这里同步清掉本地状态
    private func resetInputState() {
        latchedModifiers.removeAll()
        if keyboardVisible { setKeyboardVisible(false) }
    }

    // MARK: 外接键盘与触控板

    /// 外接键盘当前按住的键（主线程）
    private var heldKeys = Set<UInt16>()

    func sendKey(usage: UInt16, down: Bool) {
        guard connected else { return }
        if down { heldKeys.insert(usage) } else { heldKeys.remove(usage) }
        // ⌘V：iPad 上有新复制的内容就先同步给 Mac，再把按键发过去（同一条连接按顺序到达，Mac 先写剪贴板再粘贴）
        let command: Set<UInt16> = [0xE3, 0xE7]
        if down, usage == 0x19, !heldKeys.isDisjoint(with: command) || !latchedModifiers.isDisjoint(with: command) {
            clipboard.syncIfChanged()
        }
        var d = Data(capacity: 3)
        d.appendLE(usage)
        d.append(down ? 1 : 0)
        server.send(.key, d)
    }

    func sendScroll(dx: CGFloat, dy: CGFloat, phase: UInt8) {
        guard connected else { return }
        var d = Data(capacity: 9)
        d.appendLE(Float(dx).bitPattern)
        d.appendLE(Float(dy).bitPattern)
        d.append(phase)
        server.send(.scroll, d)
    }

    private func firstFrameArrived(width: Int, height: Int) {
        guard connected, let controller else { return }
        let current = controller.viewportPixels
        // 只有与当前方向一致的画面才揭开；旋转途中到达的旧方向帧不算。
        // 画面可能按比例缩小编码（流畅优先），所以比宽高比而不是尺寸
        guard width > 0, height > 0, current.width > 0, current.height > 0 else { return }
        let a = Double(width) / Double(height), b = Double(current.width) / Double(current.height)
        guard abs(a - b) / b < 0.03 else { return }
        showingStream = true
        controller.setCover(visible: false, animated: true)
    }

    /// iPad 即将旋转到新尺寸
    func viewportWillChange(to viewport: Viewport) {
        guard connected else { return }
        controller?.setCover(visible: true, animated: true)
        renderer?.targetWidth = viewport.width
        server.send(.viewport, jsonEncode(viewport))
    }

    private func makeHello(_ controller: StreamViewController) -> Hello {
        let screen = controller.view.window?.screen ?? UIScreen.main
        let native = screen.nativeBounds.size
        var model = "iPad"
        var size = 0
        sysctlbyname("hw.machine", nil, &size, nil, 0)
        if size > 0 {
            var buffer = [CChar](repeating: 0, count: size)
            sysctlbyname("hw.machine", &buffer, &size, nil, 0)
            model = String(cString: buffer)
        }
        return Hello(version: Wire.version,
                     name: UIDevice.current.name,
                     model: model,
                     deviceID: deviceID,
                     nativeWidth: Int(min(native.width, native.height)),
                     nativeHeight: Int(max(native.width, native.height)),
                     scale: Double(screen.nativeScale),
                     maxFPS: screen.maximumFramesPerSecond,
                     viewport: controller.viewportPixels,
                     caps: [PadCaps.scaledFrames, PadCaps.realtime] + (superResolutionSupported ? [PadCaps.superResolution] : []))
    }
}
