import Foundation
import CoreMedia
import CoreVideo
import CoreGraphics
import ApplicationServices
import AppKit

enum Log {
    private static let start = monotonicNs()
    /// 日志文件：~/Library/Logs/Pivot.log。每次启动清空。
    static let fileURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Pivot.log")
    private static let file: FileHandle? = {
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        return try? FileHandle(forWritingTo: fileURL)
    }()
    private static let lock = NSLock()

    static func info(_ message: @autoclosure () -> String) {
        let origin = start
        let now = monotonicNs()
        let ms = Double(now > origin ? now - origin : 0) / 1e6
        let line = Data(String(format: "[%9.1f] %@\n", ms, message()).utf8)
        lock.lock()
        FileHandle.standardError.write(line)
        file?.write(line)
        lock.unlock()
    }
}

/// 一次与 iPad 的会话：握手、建显示器、采集、编码、推流、收触控。
final class StreamSession {
    struct Snapshot {
        var deviceName = ""
        var width = 0
        var height = 0
        var pointsWidth = 0
        var pointsHeight = 0
        var fps = 0
        var hiDPI = false
        var injector = ""
        var measuredFPS = 0.0
        var mbps = 0.0
        var latencyMs = 0.0
        var encodeMs = 0.0
        var droppedFrames = 0
        var streaming = false
        var wireless = false
        var targetMbps = 0.0
        var transport = Transport.wired
        var mirror = false
        var mode = DisplayMode.extend
        /// 编码分辨率比例（100 = 原画）
        var encodePercent = 100
        /// 画面正走 UDP 实时通道
        var realtime = false
    }

    /// 连接方式：有线（USB）、同一局域网无线、跨网络远程
    enum Transport: String {
        case wired, local, remote
        var label: String {
            switch self {
            case .wired: return "有线"
            case .local: return "无线"
            case .remote: return "远程"
            }
        }
    }

    /// 有线会话对应的 usbmuxd 设备号；无线会话为 nil
    let wiredDeviceID: Int?
    var isWireless: Bool { wiredDeviceID == nil }
    let transport: Transport
    /// 镜像 Mac 主屏，而不是另开一块扩展屏
    private(set) var mirror: Bool
    /// 只用 iPad：其余显示器都镜像 Pivot 的虚拟显示器（仅扩展屏模式下有意义）
    private var solo: Bool
    var mode: DisplayMode { mirror ? .mirror : solo ? .solo : .extend }
    /// iPad 工具条上选了显示模式（主线程回调）
    var onModeRequest: ((DisplayMode) -> Void)?
    /// 有线会话里要交给 iPad 的远程组网参数（按设备标识取）
    var meshFor: ((String) -> MeshConfig?)?
    private(set) var deviceID: String?
    private var adoptable: VirtualDisplay?
    private let channel: Channel
    private let frameQueue = DispatchQueue(label: "pivot.frames", qos: .userInteractive)
    private lazy var capturer = ScreenCapturer(queue: frameQueue)

    private var hello: Hello?
    private var viewport = Viewport(width: 0, height: 0)
    private var scale: Double
    private var fps = 60
    /// 实际采集帧率。流畅优先：无线时一直保持满帧（远程最高 60），带宽紧张先降编码分辨率，
    /// 只有码率掉到底才退到 30 帧
    private var captureFPS = 60
    /// 编码分辨率相对画面的比例。iPad 端会把画面拉伸铺满，只是糊一点，帧率和跟手不受影响
    private var encodeScale = 1.0
    /// 实际编码、采集的像素尺寸（偶数）
    private var encodeSize: (Int, Int) {
        let even = { (v: Int) in max(2, Int((Double(v) * self.encodeScale / 2).rounded()) * 2) }
        return (even(viewport.width), even(viewport.height))
    }
    private var textFocusTimer: Timer?
    /// 每秒记一次显示器在排列里的位置；布局切换途中不记（placementReady 为 false）
    private var placementTimer: Timer?
    private var placementReady = false
    /// 声音（iPad 要了才开，关了连采集都停）
    private var audio: AudioStreamer?
    private let clipboard = ClipboardSync()
    private var lastTextFocus = false
    /// 正在进行的点按（主线程）：起点和时间
    private var tapStarts: [UInt8: (x: Float, y: Float, t: UInt64)] = [:]
    /// 已经打开过辅助功能树的应用（Chrome、Electron 默认不提供，要先打开才能看到网页里的输入框）
    private var axEnabledPIDs = Set<pid_t>()
    private var display: VirtualDisplay?
    private var injector: TouchInjector?
    private let keyboard = KeyboardInjector()
    private var ended = false

    // 仅在 frameQueue 上访问
    private var encoder: VideoEncoder?
    private var lastBuffer: CVPixelBuffer?
    private var pendingBuffer: CVPixelBuffer?
    private var pendingCaptureNs: UInt64 = 0
    private var refineWork: DispatchWorkItem?

    // 统计
    private let statsLock = NSLock()
    private var captureTimes: [UInt32: UInt64] = [:]
    private var ackCount = 0
    private var bytesSent = 0
    private var latencyEMA = 0.0
    private var encodeEMA = 0.0
    private var dropped = 0
    private var lastStatsTime = monotonicNs()
    private var measuredFPS = 0.0
    private var mbps = 0.0
    private var hiDPI = false
    private var streaming = false

    /// 主线程回调。结束时把虚拟显示器交还，调用方可以留给下一次会话接着用。
    var onEnded: ((String?, VirtualDisplay?) -> Void)?
    var onChanged: (() -> Void)?
    /// 有线握手里拿到了配对密钥（设备标识、密钥、设备名）
    var onPairingKey: ((String, Data, String) -> Void)?

    // 无线码率自适应
    private static let wirelessBitrateRange = 1_500_000...28_000_000
    private var wirelessBitrate = 16_000_000
    private var lastAdaptDropped = 0
    private var calmSeconds = 0
    private var adaptTimer: Timer?

    /// - Parameters:
    ///   - wiredDeviceID: 有线会话的 usbmuxd 设备号；无线传 nil
    ///   - adopt: 上一次会话留下的虚拟显示器，匹配就直接复用
    init(channel: Channel, wiredDeviceID: Int?, transport: Transport, mode: DisplayMode, scale: Double, adopt: VirtualDisplay?) {
        self.wiredDeviceID = wiredDeviceID
        self.transport = transport
        self.mirror = mode == .mirror
        self.solo = mode == .solo
        // 远程的带宽通常小得多，从较低码率起步，再按实际情况往上加
        if transport == .remote { wirelessBitrate = 6_000_000 }
        self.scale = scale
        self.adoptable = adopt
        self.channel = channel
        channel.onMessage = { [weak self] type, payload in self?.receive(type, payload) }
        channel.onClose = { [weak self] in DispatchQueue.main.async { self?.finish(reason: nil) } }
        channel.onVideoSent = { [weak self] in
            guard let self else { return }
            self.frameQueue.async { self.flushPending() }
        }
        channel.start()
        // 握手超时：连上了但对端不是 Pivot
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.hello == nil else { return }
            self.finish(reason: "握手超时")
        }
    }

    // MARK: - 收消息（读线程）

    private func receive(_ type: MsgType, _ payload: Data) {
        switch type {
        case .touch:
            if let packet = TouchPacket.decode(payload) {
                noteTouchArrival(packet)
                injector?.handle(packet)
                DispatchQueue.main.async { self.noteTapForTextFocus(packet) }
            }
        case .key:
            guard payload.count >= 3 else { return }
            keyboard.handle(usage: payload.readLE(UInt16.self, at: 0), down: payload[payload.startIndex + 2] != 0)
        case .text:
            if let text = String(data: payload, encoding: .utf8) { keyboard.type(text) }
        case .scroll:
            guard payload.count >= 9 else { return }
            let dx = Float(bitPattern: payload.readLE(UInt32.self, at: 0)), dy = Float(bitPattern: payload.readLE(UInt32.self, at: 4))
            injector?.pointerScroll(dx: Double(dx), dy: Double(dy), phase: payload[payload.startIndex + 8])
        case .ack:
            guard payload.count >= 8 else { return }
            let index = payload.readLE(UInt32.self, at: 0)
            statsLock.lock()
            if let captured = captureTimes.removeValue(forKey: index) {
                let ms = Double(monotonicNs() - captured) / 1e6
                latencyEMA = latencyEMA == 0 ? ms : latencyEMA * 0.9 + ms * 0.1
            }
            ackCount += 1
            statsLock.unlock()
        case .keyframeRequest:
            frameQueue.async { [self] in
                encoder?.requestKeyframe()
                resendLast()
            }
        case .audioEnable:
            let on = payload.first == 1
            DispatchQueue.main.async { self.setAudio(on) }
        case .clipboard:
            // 就在读线程上写：紧跟着到的 ⌘V 处理前剪贴板已经是新内容
            clipboard.apply(payload)
        case .ping:
            channel.send(.pong, payload)
        case .hello:
            guard let hello = jsonDecode(Hello.self, payload) else { return }
            DispatchQueue.main.async { self.begin(hello) }
        case .viewport:
            guard let vp = jsonDecode(Viewport.self, payload) else { return }
            DispatchQueue.main.async { self.reconfigure(viewport: vp, scale: self.scale) }
        case .mode:
            guard let v = payload.first, let m = DisplayMode(rawValue: Int(v)) else { return }
            DispatchQueue.main.async { self.onModeRequest?(m) }
        case .bye:
            DispatchQueue.main.async { self.finish(reason: nil) }
        default:
            break
        }
    }

    // MARK: - 建立（主线程）

    private func begin(_ hello: Hello) {
        guard !ended, self.hello == nil else { return }
        guard hello.version == Wire.version else { finish(reason: "两端版本不一致，请同时更新 Mac 和 iPad 上的 Pivot"); return }
        self.hello = hello
        deviceID = hello.deviceID
        if !isWireless, let encoded = hello.pairingKey, let key = Data(base64Encoded: encoded), key.count >= 16 {
            onPairingKey?(hello.deviceID, key, hello.name)
        }
        viewport = hello.viewport
        fps = max(30, min(120, hello.maxFPS))
        if isWireless {
            captureFPS = Self.fpsTier(bitrate: wirelessBitrate, cap: streamFPSCap)
            encodeScale = canScale ? Self.scaleTier(bitrate: wirelessBitrate, remote: transport == .remote, sr: canSuperResolve) : 1
        } else {
            captureFPS = fps
        }
        Log.info("握手：\(hello.name) \(hello.model) 原生 \(hello.nativeWidth)x\(hello.nativeHeight) 画面 \(viewport.width)x\(viewport.height) \(fps)Hz 能力 \(hello.caps ?? [])")
        offerRealtime(hello)

        if mirror {
            adoptable = nil
            makeInjector()
            Log.info("镜像主屏（\(transport.label)），触控后端：\(injector?.label ?? "-")")
        } else {
            guard makeDisplay() else { return }
        }

        Task { @MainActor in
            if !self.mirror { await self.attachExtended() }
            await self.startCapture()
        }
    }

    /// 建（或沿用）扩展用的虚拟显示器，并接上触控
    private func makeDisplay() -> Bool {
        guard let hello else { return false }
        let reused = adoptable.flatMap {
            $0.matches(nativeWidth: hello.nativeWidth, nativeHeight: hello.nativeHeight, refreshRate: Double(fps), identity: hello.deviceID) ? $0 : nil
        }
        adoptable = nil
        guard let display = reused ?? VirtualDisplay(name: "Pivot", nativeWidth: hello.nativeWidth, nativeHeight: hello.nativeHeight,
                                                     refreshRate: Double(fps), identity: hello.deviceID, portrait: viewport.isPortrait, scale: scale) else {
            finish(reason: "无法创建虚拟显示器")
            return false
        }
        if reused != nil { Log.info("沿用上一次会话的虚拟显示器，窗口保持原位") }
        self.display = display
        display.onTerminated = { [weak self, weak display] in
            DispatchQueue.main.async {
                guard let self, let display, self.display === display else { return }
                self.finish(reason: "系统收回了虚拟显示器")
            }
        }
        Log.info("显示器 \(display.displayID) 已创建（\(transport.label)）")
        return true
    }

    /// 扩展屏上线并切好模式后再接触控：显示器上线前拿不到它的 UUID，原生触摸屏没法绑定
    @MainActor
    private func attachExtended() async {
        await applyLayout()
        guard !ended, !mirror, let display else { return }
        makeInjector()
        applySolo()
        Log.info("显示器 \(display.displayID) 就绪，触控后端：\(injector?.label ?? "-")")
    }

    /// 只用 iPad 时，让 Mac 其余的屏幕都镜像 Pivot 的虚拟显示器；否则解除。
    /// 虚拟显示器做镜像的主屏，菜单栏、程序坞和窗口都跟过去，方向和分辨率仍按 iPad 来。
    /// 配置只在本次登录有效，Pivot 退出或显示器消失时系统自动还原。
    private func applySolo() {
        guard let display else { return }
        let target = display.displayID
        let want = solo && !mirror && !ended
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &ids, &count)
        let others = ids.prefix(Int(count)).filter { $0 != target }
        let change = others.filter { want ? CGDisplayMirrorsDisplay($0) != target : CGDisplayMirrorsDisplay($0) == target }
        guard !change.isEmpty else { return }
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else { return }
        for d in change { CGConfigureDisplayMirrorOfDisplay(config, d, want ? target : kCGNullDirectDisplay) }
        let r = CGCompleteDisplayConfiguration(config, .forSession)
        Log.info(want ? "仅 iPad：\(change.count) 块 Mac 屏幕改为镜像 iPad（\(r == .success ? "成功" : "失败 \(r.rawValue)")）"
                      : "仅 iPad 已解除，Mac 屏幕恢复（\(r == .success ? "成功" : "失败 \(r.rawValue)")）")
    }

    /// 切换显示模式，连接不断
    func setMode(_ m: DisplayMode) {
        guard m != mode else { return }
        let wasMirror = mirror
        if (m == .mirror) != wasMirror {
            // 离开扩展屏前先把 Mac 屏幕还原
            if m == .mirror { solo = false; applySolo() } else { solo = m == .solo }
            setMirror(m == .mirror)
            return
        }
        solo = m == .solo
        guard !ended, hello != nil else { return }
        Log.info("切换到\(m.label)")
        applySolo()
        sendConfig()
        onChanged?()
    }

    /// 当前采集的显示器：镜像时是 Mac 主屏，扩展时是虚拟显示器
    private var targetDisplayID: CGDirectDisplayID? { mirror ? CGMainDisplayID() : display?.displayID }

    private func makeInjector() {
        injector?.reset()
        injector = nil
        guard let target = targetDisplayID else { return }
        // 虚拟显示器刚建好时 UUID 要等一会儿才拿得到，用带重试的那个
        let uuid = mirror ? VirtualDisplay.uuid(of: target) : display?.uuidString
        let inner = InjectorFactory.make(displayID: target, displayUUID: uuid) { [weak self] fb in
            self?.channel.send(.feedback, jsonEncode(fb))
        }
        injector = mirror ? LetterboxInjector(inner: inner, displayID: target, viewport: viewport) : inner
    }

    /// 在镜像和扩展屏之间切换，连接不断
    private func setMirror(_ on: Bool) {
        guard on != mirror else { return }
        mirror = on
        guard !ended, hello != nil else { return }
        Log.info(on ? "切换到镜像主屏" : "切换到扩展屏")
        streaming = false
        onChanged?()
        Task { @MainActor in
            await self.capturer.stop()
            guard !self.ended, self.mirror == on else { return }
            if on {
                // 扩展屏收起，上面的窗口由系统挪回主屏
                self.display = nil
                self.makeInjector()
            } else {
                guard self.makeDisplay() else { return }
                await self.attachExtended()
            }
            await self.startCapture()
        }
    }

    private var layoutGeneration = 0
    /// 正在采集的显示器编号。重建显示器后编号会变，需要重新开始采集。
    private var capturedDisplayID: CGDirectDisplayID = 0

    /// 把显示器切到当前视口与缩放对应的模式。显示器刚上线或刚换表时模式列表需要一点时间刷新，所以带重试。
    @MainActor
    @discardableResult
    private func applyLayout() async -> Bool {
        guard !mirror, let display, !ended else { return false }
        placementReady = false
        defer { DispatchQueue.main.async { self.restorePlacement() } }
        layoutGeneration += 1
        let generation = layoutGeneration
        let layout = VirtualDisplay.Layout(pixelWidth: viewport.width, pixelHeight: viewport.height, scale: scale)
        let started = monotonicNs()
        var applied = false
        var attempts = 0
        for _ in 0..<150 {
            attempts += 1
            if display.apply(layout) { applied = true; break }
            try? await Task.sleep(nanoseconds: 20_000_000)
            guard !ended, generation == layoutGeneration else {
                return false
            }
        }
        hiDPI = display.isHiDPI
        let ms = Double(monotonicNs() - started) / 1e6
        let mode = display.currentMode
        Log.info(String(format: "布局 %dx%d 点（%@）%@，耗时 %.0fms，实际 %dx%d 点 / %dx%d 像素",
                        layout.points.w, layout.points.h, layout.isPortrait ? "竖" : "横",
                        applied ? "成功（\(display.lastPath)）" : "失败：\(display.lastError ?? "?")", ms,
                        mode?.points.0 ?? 0, mode?.points.1 ?? 0, mode?.pixels.0 ?? 0, mode?.pixels.1 ?? 0))
        injector?.retarget(displayID: display.displayID)
        return applied
    }

    private var hostName: String { Host.current().localizedName ?? "Mac" }

    private func sendConfig() {
        let config = StreamConfig(width: viewport.width, height: viewport.height, fps: fps, codec: "hevc", hostName: hostName,
                                  mirror: mirror, mode: mode.rawValue, mesh: isWireless ? nil : deviceID.flatMap { meshFor?($0) }, transport: transport.rawValue)
        channel.send(.config, jsonEncode(config))
    }

    @MainActor
    private func startCapture() async {
        guard let target = targetDisplayID, !ended else { return }
        let (w, h) = encodeSize
        let f = fps
        let ef = min(f, captureFPS)
        frameQueue.sync { rebuildEncoder(width: w, height: h, fps: ef) }
        sendConfig()
        capturer.onFrame = { [weak self] buffer, _, captureNs in self?.submit(buffer, captureNs: captureNs) }
        capturer.onStopped = { [weak self] error in
            Log.info("采集中断：\(error?.localizedDescription ?? "未知")")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self?.restartCapture() }
        }
        do {
            try await capturer.start(displayID: target, width: w, height: h, fps: min(f, captureFPS))
            // 启动采集要几百毫秒，期间会话可能已经结束（比如换线）：这时立刻停掉，别留下没人管的采集
            guard !ended else { await capturer.stop(); return }
            capturedDisplayID = target
            streaming = true
            Log.info("开始推流 \(w)x\(h)@\(min(f, captureFPS))")
            onChanged?()
            startBitrateAdaptation()
            startTextFocusWatch()
            clipboard.send = { [weak self] p in self?.channel.send(.clipboard, p) }
            clipboard.start()
            runSelfTestIfRequested()
        } catch {
            finish(reason: "无法采集屏幕：\(error.localizedDescription)")
        }
    }

    /// 无线：每秒看一次有没有因为发不出去而跳帧。有就把码率降三成，连续平稳几秒再慢慢加回去。
    private func startBitrateAdaptation() {
        guard isWireless, adaptTimer == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] t in
            guard let self, !self.ended else { t.invalidate(); return }
            self.statsLock.lock()
            let droppedNow = self.dropped
            self.statsLock.unlock()
            let delta = droppedNow - self.lastAdaptDropped
            self.lastAdaptDropped = droppedNow
            var next = self.wirelessBitrate
            if delta >= 3 {
                next = Int(Double(next) * 0.7)
                self.calmSeconds = 0
            } else if delta == 0 {
                self.calmSeconds += 1
                if self.calmSeconds >= 4 { next = Int(Double(next) * 1.12); self.calmSeconds = 2 }
            } else {
                self.calmSeconds = 0
            }
            next = min(Self.wirelessBitrateRange.upperBound, max(Self.wirelessBitrateRange.lowerBound, next))
            guard next != self.wirelessBitrate else { return }
            self.wirelessBitrate = next
            self.frameQueue.async { self.encoder?.setBitrate(next) }
            (self.channel as? HybridChannel)?.setBitrate(next)
            let tier = Self.fpsTier(bitrate: next, cap: self.streamFPSCap, current: self.captureFPS)
            let scale = self.canScale ? Self.scaleTier(bitrate: next, remote: self.transport == .remote, sr: self.canSuperResolve, current: self.encodeScale) : 1
            guard tier != self.captureFPS || scale != self.encodeScale else { return }
            Log.info(String(format: "码率 %.1f Mbps：编码 %.0f%% 分辨率，%d 帧", Double(next) / 1e6, scale * 100, tier))
            self.captureFPS = tier
            self.applyEncodeScale(scale)
        }
        RunLoop.main.add(timer, forMode: .common)
        adaptTimer = timer
    }

    /// iPad 支持时打开 UDP 实时通道（画面、触控、回执改走 UDP；控制消息仍走 TLS）
    private func offerRealtime(_ hello: Hello) {
        guard isWireless, hello.caps?.contains(PadCaps.realtime) == true, let hybrid = channel as? HybridChannel,
              ProcessInfo.processInfo.environment["PIVOT_RT"] != "off",
              let port = PairingStore.remotePort(for: hello.deviceID), let key = PairingStore.key(for: hello.deviceID),
              let offer = hybrid.enableRealtime(port: port, pairingKey: key) else { return }
        hybrid.setBitrate(wirelessBitrate)
        hybrid.onRealtimeLoss = { [weak self] n in
            guard let self else { return }
            // 补不回来的帧按跳帧算，码率自适应会因此降码率
            self.statsLock.lock(); self.dropped += n; self.statsLock.unlock()
        }
        channel.send(.rtOffer, jsonEncode(offer))
        Log.info("实时通道：UDP 端口 \(port)，等 iPad 接入")
    }

    /// 旧版 iPad 只认和画面区域一样大的帧（否则一直停在「正在准备画面」），所以只对声明过的 iPad 降编码分辨率
    private var canScale: Bool { hello?.caps?.contains(PadCaps.scaledFrames) ?? false }
    private var canSuperResolve: Bool { hello?.caps?.contains(PadCaps.superResolution) ?? false }

    /// 无线推流的帧率上限：局域网跟随 iPad（可到 120），远程最多 60，省下的带宽给清晰度
    private var streamFPSCap: Int { transport == .remote ? min(fps, 60) : fps }

    /// 帧率只在码率掉到底时才降到 30，其余时候一直满帧
    private static func fpsTier(bitrate: Int, cap: Int, current: Int? = nil) -> Int {
        let low = min(cap, 30)
        if let current, current == low, cap != low { return bitrate >= 2_600_000 ? cap : low }
        return bitrate >= 2_000_000 ? cap : low
    }

    /// 码率对应的编码分辨率比例。档位之间留缓冲：升档要比门槛高 20%，降档要比当前档门槛低 12%，
    /// 码率在边界附近来回波动时分辨率不跟着反复跳（每次切换都要重建编码器、发一个关键帧）
    private static func scaleTier(bitrate: Int, remote: Bool, sr: Bool = false, current: Double? = nil) -> Double {
        // 远程整体低一档：帧更小，网络抖一下时更快追上，跟手优先。
        // iPad 能超分时中间两档再小一点：源画面不超过 1280 宽才能超分，放大回来比直接拉伸清楚
        let tiers: [(threshold: Int, scale: Double)] = remote
            ? (sr ? [(11_000_000, 0.8), (6_500_000, 0.55), (3_800_000, 0.45), (0, 0.4)]
                  : [(11_000_000, 0.8), (6_500_000, 0.65), (3_800_000, 0.5), (0, 0.4)])
            : [(11_000_000, 1.0), (6_500_000, 0.8), (3_800_000, 0.65), (0, 0.5)]
        let plain = tiers.first { bitrate >= $0.threshold }!.scale
        guard let current, plain != current, let cur = tiers.firstIndex(where: { $0.scale == current }) else { return plain }
        let up = plain > current
        if up, let next = tiers[..<cur].last, bitrate < Int(Double(next.threshold) * 1.2) { return current }
        if !up, bitrate > Int(Double(tiers[cur].threshold) * 0.88) { return current }
        return plain
    }

    /// 换编码分辨率：先按新尺寸重建编码器，再让采集改尺寸；中间到的旧尺寸帧会被丢掉
    private func applyEncodeScale(_ scale: Double) {
        encodeScale = scale
        let (w, h) = encodeSize
        let (f, cf) = (fps, captureFPS)
        frameQueue.async {
            self.lastBuffer = nil
            self.pendingBuffer = nil
            self.refineWork?.cancel()
            self.rebuildEncoder(width: w, height: h, fps: min(f, cf))
        }
        Task { await self.capturer.update(width: w, height: h, fps: min(f, cf)) }
    }

    /// 布局切好后把显示器放回上次的位置，然后开始记录用户之后的调整（主线程）
    private func restorePlacement() {
        guard !ended, !mirror, let display, let id = hello?.deviceID else { return }
        if let saved = DisplayPlacement.load(deviceID: id) { DisplayPlacement.restore(display.displayID, saved) }
        placementReady = true
        guard placementTimer == nil else { return }
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] t in
            guard let self, !self.ended else { t.invalidate(); return }
            self.rememberPlacement()
        }
        RunLoop.main.add(t, forMode: .common)
        placementTimer = t
    }

    private func rememberPlacement() {
        guard placementReady, !mirror, let display, let id = hello?.deviceID,
              let now = DisplayPlacement.capture(display.displayID) else { return }
        DisplayPlacement.save(now, deviceID: id)
    }

    /// 主线程
    private func setAudio(_ on: Bool) {
        if on, !ended {
            guard audio == nil else { return }
            let a = AudioStreamer()
            a.onPacket = { [weak self] p in self?.channel.send(.audio, p) }
            audio = a
            Task {
                do { try await a.start(); Log.info("声音：开始传输") }
                catch { Log.info("声音：采集失败 \(error.localizedDescription)") }
            }
        } else if let a = audio {
            audio = nil
            Task { await a.stop(); Log.info("声音：已停止") }
        }
    }

    /// 每 0.25 秒看一次 Mac 上的焦点是不是输入框，变化时告诉 iPad（iPad 刚点过画面才会弹出屏幕键盘）
    private func startTextFocusWatch() {
        guard textFocusTimer == nil else { return }
        Log.info("输入框检测：辅助功能权限 \(AXIsProcessTrusted() ? "已授权" : "未授权，iPad 无法自动弹出键盘")")
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] t in
            guard let self, !self.ended else { t.invalidate(); return }
            let isText = self.focusedIsText()
            guard isText != self.lastTextFocus else { return }
            self.lastTextFocus = isText
            self.channel.send(.textFocus, Data([isText ? 1 : 0]))
        }
        RunLoop.main.add(timer, forMode: .common)
        textFocusTimer = timer
    }

    /// iPad 上点了一下（不是拖动）：稍后再看一次焦点。焦点本来就在输入框里时（比如收起键盘后再点同一个框）
    /// 焦点不会变化，定时检测发现不了，这里补发一次，让 iPad 重新弹出键盘
    private func noteTapForTextFocus(_ packet: TouchPacket) {
        for c in packet.contacts where c.kind == .finger || c.kind == .pencil {
            switch c.phase {
            case .began:
                tapStarts[c.id] = (c.x, c.y, packet.timestamp)
            case .ended:
                guard let s = tapStarts.removeValue(forKey: c.id) else { continue }
                let still = abs(c.x - s.x) < 0.02 && abs(c.y - s.y) < 0.02
                let quick = packet.timestamp > s.t && packet.timestamp - s.t < 800_000_000
                if still && quick { recheckTextFocusAfterTap() }
            case .cancelled:
                tapStarts[c.id] = nil
            default:
                break
            }
        }
    }

    private func recheckTextFocusAfterTap() {
        // 点击后应用要一点时间才把焦点移过去
        for delay in [0.15, 0.45] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, !self.ended else { return }
                let isText = self.focusedIsText()
                self.lastTextFocus = isText
                if isText { self.channel.send(.textFocus, Data([1])) }
            }
        }
    }

    /// 当前焦点是不是能输入文字的地方：认常见的输入框角色，也认「值可改且有光标选区」的元素（网页里的富文本编辑区等）
    private func focusedIsText() -> Bool {
        var focused: CFTypeRef?
        if let app = NSWorkspace.shared.frontmostApplication {
            let pid = app.processIdentifier
            let appElement = AXUIElementCreateApplication(pid)
            if axEnabledPIDs.insert(pid).inserted {
                AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            }
            AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focused)
        }
        if focused == nil {
            AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute as CFString, &focused)
        }
        guard let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return false }
        let element = focused as! AXUIElement
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        let editable: Set<String> = ["AXTextField", "AXTextArea", "AXSearchField", "AXComboBox", "AXSecureTextField"]
        if let role = role as? String, editable.contains(role) { return true }
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success, settable.boolValue else { return false }
        var range: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &range) == .success
    }

    /// 自测：`PIVOT_SELFTEST=rotate` 时模拟 iPad 来回旋转，并定时打印统计
    private var selfTestStarted = false

    // 触控到达的抖动（读线程写、统计时取走）。iPad 每 8～16 ms 发一包，到达间隔忽大忽小就是网络在攒包
    private var touchStats = (count: 0, maxGap: UInt64(0), lastArrival: UInt64(0), minSkew: Int64.max, maxSkew: Int64.min)

    private func noteTouchArrival(_ packet: TouchPacket) {
        let now = monotonicNs()
        statsLock.lock()
        defer { statsLock.unlock() }
        if touchStats.lastArrival != 0, now - touchStats.lastArrival < 300_000_000 {
            touchStats.maxGap = max(touchStats.maxGap, now - touchStats.lastArrival)
        }
        touchStats.lastArrival = now
        touchStats.count += 1
        // 两台机器时钟不同，只看「到达时间 - 发出时间」的波动幅度
        let skew = Int64(bitPattern: now &- packet.timestamp)
        touchStats.minSkew = min(touchStats.minSkew, skew)
        touchStats.maxSkew = max(touchStats.maxSkew, skew)
    }

    private func takeTouchStats() -> String {
        statsLock.lock()
        defer { statsLock.unlock() }
        let t = touchStats
        touchStats = (0, 0, t.lastArrival, .max, .min)
        guard t.count > 1 else { return "" }
        return String(format: "  触控 %d 包 抖动 %.0f ms 最大间隔 %.0f ms", t.count, Double(t.maxSkew - t.minSkew) / 1e6, Double(t.maxGap) / 1e6)
    }

    private func runSelfTestIfRequested() {
        guard !selfTestStarted, let mode = ProcessInfo.processInfo.environment["PIVOT_SELFTEST"] else { return }
        selfTestStarted = true
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] t in
            guard let self, !self.ended else { t.invalidate(); return }
            let s = self.snapshot()
            Log.info(String(format: "统计 %.0f fps  %.1f Mbps  延迟 %.1f ms  编码 %.1f ms  跳帧 %d", s.measuredFPS, s.mbps, s.latencyMs, s.encodeMs, s.droppedFrames) + self.takeTouchStats())
        }
        RunLoop.main.add(timer, forMode: .common)
        if mode == "mirror" {
            // 走和 iPad 工具条相同的路径，几种模式两两之间都切一遍；中间转一次竖屏↔横屏看「仅 iPad」跟不跟
            let steps: [DisplayMode] = [.mirror, .extend, .solo, .extend, .mirror, .solo, .mirror, .extend]
            for (i, m) in steps.enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + 4 + Double(i) * 5) { [weak self] in
                    guard let self, !self.ended else { return }
                    Log.info("自测：请求\(m.label)")
                    self.onModeRequest?(m)
                    if i == 2 {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                            Log.info("自测：仅 iPad 下旋转")
                            self?.flipForSelfTest()
                        }
                    }
                }
            }
            return
        }
        guard mode == "rotate" else { return }
        // 旋转 → 转回 → 改缩放（会用到显式切换）→ 再旋转（显式切换后的换表最容易出问题）→ 转回 → 恢复缩放
        let original = scale
        let steps: [(Double, String, () -> Void)] = [
            (3, "转竖屏", { [weak self] in self?.flipForSelfTest() }),
            (6, "转回横屏", { [weak self] in self?.flipForSelfTest() }),
            (9, "缩放改为 1.2", { [weak self] in self?.setScale(1.2) }),
            (12, "缩放 1.2 下转竖屏", { [weak self] in self?.flipForSelfTest() }),
            (15, "转回横屏", { [weak self] in self?.flipForSelfTest() }),
            (18, "缩放恢复", { [weak self] in self?.setScale(original) }),
        ]
        for (delay, title, action) in steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, !self.ended else { return }
                Log.info("自测：\(title)")
                action()
            }
        }
    }

    private func flipForSelfTest() {
        reconfigure(viewport: Viewport(width: viewport.height, height: viewport.width), scale: scale)
    }

    private func restartCapture() {
        Task { @MainActor in await self.recapture() }
    }

    /// 停掉当前采集，对准（可能已经换了编号的）显示器重新开始
    @MainActor
    private func recapture() async {
        guard !ended, let target = targetDisplayID else { return }
        let (w, h) = encodeSize
        let f = fps
        await capturer.stop()
        do {
            try await capturer.start(displayID: target, width: w, height: h, fps: min(f, captureFPS))
            guard !ended else { await capturer.stop(); return }
            capturedDisplayID = target
        } catch {
            finish(reason: "无法采集屏幕：\(error.localizedDescription)")
        }
    }

    /// 方向、尺寸或缩放档位变化
    func reconfigure(viewport newViewport: Viewport, scale newScale: Double) {
        guard !ended, hello != nil, mirror || display != nil else { return }
        guard newViewport.width > 0, newViewport.height > 0 else { return }
        let sizeChanged = newViewport != viewport
        guard sizeChanged || newScale != scale else { return }
        viewport = newViewport
        scale = newScale
        injector?.reset()
        let (w, h) = encodeSize
        let f = fps
        if sizeChanged {
            // 先停掉旧尺寸的编码，避免换表途中的过渡画面被送出去
            frameQueue.sync {
                lastBuffer = nil
                pendingBuffer = nil
                refineWork?.cancel()
                encoder?.invalidate()
                encoder = nil
            }
        }
        if mirror { (injector as? LetterboxInjector)?.update(viewport: viewport) }
        Task { @MainActor in
            if !self.mirror { guard await self.applyLayout() else { return } }
            let displayReplaced = self.targetDisplayID.map { $0 != self.capturedDisplayID } ?? false
            if sizeChanged {
                let ef = min(f, self.captureFPS)
                self.frameQueue.sync { self.rebuildEncoder(width: w, height: h, fps: ef) }
                self.sendConfig()
            }
            if displayReplaced {
                Log.info("显示器已重建，重新开始采集")
                self.applySolo()
                await self.recapture()
            } else if sizeChanged {
                await self.capturer.update(width: w, height: h, fps: min(f, self.captureFPS))
            }
            self.onChanged?()
        }
        onChanged?()
    }

    func setScale(_ s: Double) { reconfigure(viewport: viewport, scale: s) }

    // MARK: - 帧管线（frameQueue）

    private func rebuildEncoder(width: Int, height: Int, fps: Int) {
        encoder?.invalidate()
        let enc = VideoEncoder(width: width, height: height, fps: fps, bitrate: isWireless ? wirelessBitrate : nil)
        enc?.onOutput = { [weak self] out in self?.send(out) }
        encoder = enc
        if enc == nil { Log.info("编码器创建失败 \(width)x\(height)") }
    }

    private func submit(_ buffer: CVPixelBuffer, captureNs: UInt64) {
        guard let encoder, CVPixelBufferGetWidth(buffer) == encoder.width, CVPixelBufferGetHeight(buffer) == encoder.height else { return }
        lastBuffer = buffer
        // 对端来不及收时不排队：只留最新一帧，等通道空了再编，延迟不会越积越多
        if channel.videoBacklog >= 2 {
            pendingBuffer = buffer
            pendingCaptureNs = captureNs
            statsLock.lock(); dropped += 1; statsLock.unlock()
            return
        }
        pendingBuffer = nil
        encode(buffer, captureNs: captureNs)
        scheduleRefine()
    }

    private func flushPending() {
        guard let buffer = pendingBuffer, channel.videoBacklog < 2 else { return }
        pendingBuffer = nil
        encode(buffer, captureNs: pendingCaptureNs)
        scheduleRefine()
    }

    private func resendLast() {
        guard let buffer = lastBuffer, channel.videoBacklog < 2 else { return }
        encode(buffer, captureNs: monotonicNs())
    }

    private func encode(_ buffer: CVPixelBuffer, captureNs: UInt64) {
        encoder?.encode(buffer, pts: CMTime(value: CMTimeValue(monotonicNs()), timescale: 1_000_000_000), captureNs: captureNs)
    }

    /// 画面静止后补编两次同一帧，让码率控制把残留的压缩痕迹收干净
    private func scheduleRefine() {
        refineWork?.cancel()
        var pass = 0
        func arm(after delay: Double) {
            let work = DispatchWorkItem { [weak self] in
                guard let self, !self.ended else { return }
                self.resendLast()
                pass += 1
                if pass < 2 { arm(after: 0.25) }
            }
            refineWork = work
            frameQueue.asyncAfter(deadline: .now() + delay, execute: work)
        }
        arm(after: 0.12)
    }

    private func send(_ out: VideoEncoder.Output) {
        if let format = out.format { channel.send(.format, format) }
        statsLock.lock()
        captureTimes[out.index] = out.captureNs
        if captureTimes.count > 240 { captureTimes = captureTimes.filter { out.index &- $0.key < 120 } }
        bytesSent += out.data.count
        let enc = Double(out.encodeMicros) / 1000
        encodeEMA = encodeEMA == 0 ? enc : encodeEMA * 0.9 + enc * 0.1
        statsLock.unlock()
        channel.sendVideo(header: VideoHeader(isKey: out.isKey, index: out.index, captureNs: out.captureNs), data: out.data)
    }

    // MARK: - 状态

    func snapshot() -> Snapshot {
        statsLock.lock()
        let now = monotonicNs()
        let dt = Double(now - lastStatsTime) / 1e9
        if dt >= 0.5 {
            measuredFPS = Double(ackCount) / dt
            mbps = Double(bytesSent) * 8 / dt / 1e6
            ackCount = 0
            bytesSent = 0
            lastStatsTime = now
        }
        var s = Snapshot()
        s.measuredFPS = measuredFPS
        s.mbps = mbps
        s.latencyMs = latencyEMA
        s.encodeMs = encodeEMA
        s.droppedFrames = dropped
        statsLock.unlock()
        s.deviceName = hello?.name ?? ""
        s.width = viewport.width
        s.height = viewport.height
        let p = VirtualDisplay.points(pixelWidth: viewport.width, pixelHeight: viewport.height, scale: scale)
        s.pointsWidth = p.w
        s.pointsHeight = p.h
        s.fps = min(fps, captureFPS)
        s.encodePercent = Int((encodeScale * 100).rounded())
        s.realtime = (channel as? HybridChannel)?.realtimeActive ?? false
        s.hiDPI = hiDPI
        s.injector = injector?.label ?? ""
        s.streaming = streaming
        s.wireless = isWireless
        s.targetMbps = isWireless ? Double(wirelessBitrate) / 1e6 : 0
        s.transport = transport
        s.mirror = mirror
        s.mode = mode
        return s
    }

    // MARK: - 结束（主线程）

    /// - Parameter final: 用户主动停止（暂停、退出）。iPad 收到后立刻回到等待界面，不再保留画面等重连。
    func stop(final: Bool = false) {
        channel.send(.bye, Data([final ? 1 : 0]))
        finish(reason: nil)
    }

    private func finish(reason: String?) {
        guard !ended else { return }
        ended = true
        applySolo()
        streaming = false
        Log.info("会话结束\(reason.map { "：\($0)" } ?? "")")
        injector?.reset()
        injector = nil
        keyboard.releaseAll()
        let capturer = self.capturer
        Task { await capturer.stop() }
        frameQueue.async { [self] in
            refineWork?.cancel()
            encoder?.invalidate()
            encoder = nil
            lastBuffer = nil
            pendingBuffer = nil
        }
        // 稍后再关通道，让 bye 有机会发出去
        let channel = self.channel
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { channel.close() }
        adaptTimer?.invalidate()
        textFocusTimer?.invalidate()
        placementTimer?.invalidate()
        rememberPlacement()
        clipboard.stop()
        setAudio(false)
        let display = self.display
        self.display = nil
        onEnded?(reason, display)
    }
}
