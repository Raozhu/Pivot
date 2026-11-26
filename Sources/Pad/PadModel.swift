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

    // MARK: 退到后台再回来
    /// 后台保活最长多久：超过就按全新连接处理（回加载页）
    private static let resumeWindow: TimeInterval = 300
    private var backgroundedAt: Date?
    private var backgroundTask = UIBackgroundTaskIdentifier.invalid
    /// 后台时连接已关掉，但画面和状态都还留着，回来就重连
    private var parkedInBackground = false
    /// 后台期间 Mac 主动彻底结束了（比如在 Mac 上点了断开）：回来不再重连
    private var endedWhileAway = false

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
    /// 滚动先行：单指竖向滑动时 iPad 先挪画面
    @Published var scrollAhead = PadModel.setting("scrollAhead") {
        didSet { UserDefaults.standard.set(scrollAhead, forKey: "scrollAhead"); controller?.streamView.scrollAhead = scrollAhead }
    }
    @Published var touchPredict = PadModel.setting("touchPredict") {
        didSet { UserDefaults.standard.set(touchPredict, forKey: "touchPredict"); controller?.streamView.predictTouches = touchPredict }
    }
    /// 小画面在 iPad 上超分放大
    @Published var superResolution = PadModel.setting("superResolution") {
        didSet { UserDefaults.standard.set(superResolution, forKey: "superResolution"); renderer?.superResolution = superResolution }
    }
    let superResolutionSupported = VideoRenderer.superResolutionSupported

    /// 清晰度：带宽不够时先保分辨率还是先保帧率
    @Published var quality = StreamQuality(rawValue: UInt8(UserDefaults.standard.integer(forKey: "quality"))) ?? .auto {
        didSet {
            guard quality != oldValue else { return }
            UserDefaults.standard.set(Int(quality.rawValue), forKey: "quality")
            if connected { server.send(.quality, Data([quality.rawValue])) }
            let on = quality == .smooth
            server.eventQueue.async { self.pacing = on }
        }
    }

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
        renderer.onNeedKeyframe = { [weak self] refreshOK in self?.requestKeyframe(refreshOK: refreshOK) }
        renderer.onFirstFrame = { [weak self] w, h in
            DispatchQueue.main.async { self?.firstFrameArrived(width: w, height: h) }
        }
        renderer.superResolution = superResolution
        controller.streamView.predictTouches = touchPredict
        controller.streamView.scrollAhead = scrollAhead
        self.renderer = renderer
        controller.streamView.onTouches = { [weak self] packet in
            self?.lastTouchNs = monotonicNs()
            guard let self, self.connected else { return }
            PadTelemetry.shared.touchSent(eventNs: packet.timestamp)
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

    /// App 退到后台。推流中不断开：让 Mac 暂停发画面和声音，向系统争取约 30 秒后台时间，
    /// 这段时间里回来连接还在，直接接着用；快到期时再关连接（Mac 把显示器留 5 分钟）。
    func enterBackground() {
        guard started, connected, showingStream else { stop(); return }
        backgroundedAt = Date()
        server.send(.pause, Data([1]))
        player.stop()
        endBackgroundTask()
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "pivot.keepalive") { [weak self] in
            self?.parkInBackground()
        }
    }

    /// App 回到前台
    func enterForeground() {
        endBackgroundTask()
        let away = backgroundedAt.map { Date().timeIntervalSince($0) } ?? 0
        backgroundedAt = nil
        if started, connected {
            // 连接还在：直接继续
            server.send(.pause, Data([0]))
            lastKeyframeRequest = 0
            requestKeyframe(refreshOK: false)
            applyAudio()
            return
        }
        guard parkedInBackground else { start(); return }
        parkedInBackground = false
        let ended = endedWhileAway
        endedWhileAway = false
        guard !ended, away < Self.resumeWindow, showingStream else {
            endStream()
            start()
            return
        }
        // 画面留着，顶上显示“正在重新连接…”。远程要重新打洞，宽限放宽到 10 秒
        reconnecting = true
        armGrace(seconds: 10)
        start()
    }

    /// 后台时间快用完（或后台里连接自己断了）：关掉连接和组网，但画面和会话状态留着
    private func parkInBackground() {
        guard backgroundedAt != nil, !parkedInBackground else { endBackgroundTask(); return }
        parkedInBackground = true
        if started {
            started = false
            mesh.stop()
            // 不带“彻底结束”标记：Mac 看到 iPad 是在后台时断的，会把虚拟显示器留 5 分钟
            server.stop()
        }
        connected = false
        player.stop()
        heldKeys.removeAll()
        mesh.setConnected(false)
        controller?.streamView.resetTouches()
        resetInputState()
        graceGeneration += 1
        reconnecting = false
        endBackgroundTask()
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    /// 宽限期内没连回来就收起画面回到等待界面
    private func armGrace(seconds: Double) {
        graceGeneration += 1
        let generation = graceGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, self.graceGeneration == generation, !self.connected else { return }
            self.endStream()
        }
    }

    // MARK: 网络事件（网络队列）

    private var lastKeyframeRequest: UInt64 = 0

    private func requestKeyframe(refreshOK: Bool) {
        // 限流：最多每 250ms 请求一次
        let now = monotonicNs()
        guard now - lastKeyframeRequest > 250_000_000 else { return }
        lastKeyframeRequest = now
        server.send(.keyframeRequest, Data([refreshOK ? 1 : 0]))
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
            flushPaced()
            renderer?.setFormat(payload)
        case .video(let header, let data):
            present(header, data)
        case .rtVideo(let frame):
            // UDP 来的关键帧自带参数集
            if let format = frame.format { flushPaced(); renderer?.setFormat(format) }
            present(VideoHeader(isKey: frame.isKey, index: frame.index, captureNs: frame.captureNs, isRefresh: frame.isRefresh), frame.data)
            let ts = frame.touchTs
            if ts > 0 { DispatchQueue.main.async { self.controller?.streamView.frameShown(touchTs: ts) } }
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

    // 画面匀开（仅“流畅优先”）：网络把几帧攒在一起送到时，按约 14 ms 一帧放出来，不一下子跳过去。
    // 排队超过 2 帧、或者来了关键帧就不再等，延迟不会越积越多。都在网络队列上
    private lazy var pacing = quality == .smooth
    private var paced: [(VideoHeader, Data)] = []
    private var lastShownNs: UInt64 = 0
    private static let paceIntervalNs: UInt64 = 14_000_000

    private func present(_ header: VideoHeader, _ data: Data) {
        guard pacing else { lastShownNs = monotonicNs(); show(header, data); return }
        if header.isKey { flushPaced() }
        paced.append((header, data))
        if paced.count == 1 { drainPaced() }
    }

    private func drainPaced() {
        while let (h, d) = paced.first {
            let now = monotonicNs()
            let due = lastShownNs + Self.paceIntervalNs
            guard now >= due || paced.count > 2 || h.isKey else {
                server.eventQueue.asyncAfter(deadline: .now() + .nanoseconds(Int(due - now))) { [weak self] in self?.drainPaced() }
                return
            }
            paced.removeFirst()
            lastShownNs = now
            show(h, d)
        }
    }

    private func flushPaced() {
        while !paced.isEmpty { let (h, d) = paced.removeFirst(); show(h, d) }
        lastShownNs = monotonicNs()
    }

    /// 送显并回执（网络队列）
    private func show(_ header: VideoHeader, _ data: Data) {
        let started = monotonicNs()
        logStats(header, bytes: data.count)
        PadTelemetry.shared.frameArrived(started)
        guard renderer?.enqueue(header, data) == true else { return }
        PadTelemetry.shared.decoded(monotonicNs() - started)
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
        PadTelemetry.shared.start { [weak self] stats in
            guard let self, self.connected else { return }
            self.server.send(.padStats, jsonEncode(stats))
        }
    }

    /// - Parameter final: 对端主动结束或应用退到后台。否则先保留画面几秒，等对端从另一条线路重连。
    private func didDisconnect(final: Bool) {
        // 后台里断的（或后台到期主动关的）：不走宽限，画面留着等回到前台再重连
        if backgroundedAt != nil || parkedInBackground {
            if final { endedWhileAway = true }
            if backgroundedAt != nil { parkInBackground() }
            return
        }
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
        armGrace(seconds: 4)
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
                     caps: [PadCaps.scaledFrames, PadCaps.realtime] + (superResolutionSupported ? [PadCaps.superResolution] : []),
                     quality: quality.rawValue)
    }
}

import Network
import QuartzCore

/// iPad 端实况采集：收帧、上屏、触控、主线程卡顿、网络类型和发热。每秒汇总一次交给 PadModel 发给 Mac
final class PadTelemetry: NSObject {
    static let shared = PadTelemetry()
    private let lock = NSLock()
    private var frames = 0, frameGapMax: UInt64 = 0, frameHitches = 0, lastFrame: UInt64 = 0, prevGap: UInt64 = .max
    private var presented = 0, presentGapMax: UInt64 = 0, lastPresent: UInt64 = 0
    private var decodeMax: UInt64 = 0
    private var touches = 0, touchLagMax: UInt64 = 0
    private var mainHitchMax: CFTimeInterval = 0
    private var link: CADisplayLink?
    private var lastLink: CFTimeInterval = 0
    private var timer: DispatchSourceTimer?
    private let path = NWPathMonitor()
    private var net = "other"
    private var send: ((PadStats) -> Void)?

    func start(_ send: @escaping (PadStats) -> Void) {
        lock.lock(); self.send = send; lock.unlock()
        guard timer == nil else { return }
        path.pathUpdateHandler = { [weak self] p in
            let n = p.usesInterfaceType(.wifi) ? "wifi" : p.usesInterfaceType(.cellular) ? "cellular" : p.usesInterfaceType(.wiredEthernet) ? "wired" : "other"
            self?.lock.lock(); self?.net = n; self?.lock.unlock()
        }
        path.start(queue: .global(qos: .utility))
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        t.schedule(deadline: .now() + 1, repeating: 1)
        t.setEventHandler { [weak self] in self?.flush() }
        t.resume()
        timer = t
    }

    @objc private func tick(_ l: CADisplayLink) {
        if lastLink != 0 {
            let d = l.timestamp - lastLink
            lock.lock(); mainHitchMax = max(mainHitchMax, d); lock.unlock()
        }
        lastLink = l.timestamp
    }

    func frameArrived(_ now: UInt64) {
        lock.lock(); defer { lock.unlock() }
        frames += 1
        if lastFrame != 0, now - lastFrame < 500_000_000 {
            let g = now - lastFrame
            frameGapMax = max(frameGapMax, g)
            // 只算“画面本来在连续动、突然断了一下”：静止时帧本来就稀，不算卡顿
            if g > 40_000_000, prevGap < 25_000_000 { frameHitches += 1 }
            prevGap = g
        }
        lastFrame = now
    }

    func decoded(_ ns: UInt64) { lock.lock(); decodeMax = max(decodeMax, ns); lock.unlock() }

    func presentedFrame() {
        let now = monotonicNs()
        lock.lock(); defer { lock.unlock() }
        presented += 1
        if lastPresent != 0, now - lastPresent < 500_000_000 { presentGapMax = max(presentGapMax, now - lastPresent) }
        lastPresent = now
    }

    func touchSent(eventNs: UInt64) {
        let now = monotonicNs()
        lock.lock(); defer { lock.unlock() }
        touches += 1
        if now > eventNs, now - eventNs < 2_000_000_000 { touchLagMax = max(touchLagMax, now - eventNs) }
    }

    private func flush() {
        lock.lock()
        let ms = { (v: UInt64) in Double(v) / 1e6 }
        let s = PadStats(frames: frames, frameGapMax: ms(frameGapMax), frameHitches: frameHitches,
                         presented: presented, presentGapMax: ms(presentGapMax), decodeMax: ms(decodeMax),
                         touches: touches, touchLagMax: ms(touchLagMax), mainHitchMax: mainHitchMax * 1000,
                         net: net, thermal: ProcessInfo.processInfo.thermalState.rawValue,
                         lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled)
        frames = 0; frameGapMax = 0; frameHitches = 0; presented = 0; presentGapMax = 0; decodeMax = 0
        touches = 0; touchLagMax = 0; mainHitchMax = 0
        let send = self.send
        lock.unlock()
        send?(s)
    }
}
