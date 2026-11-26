import Foundation
import AppKit
import Combine
import ApplicationServices
import Network
import ServiceManagement

/// 发现 USB 上的 iPad，等它打开 Pivot，然后建立会话。界面状态都从这里发布。
final class HostController: ObservableObject {
    static let shared = HostController()

    enum Phase: Equatable {
        case noDevice
        case waitingForApp
        case connecting
        case streaming
        case failed(String)
    }

    @Published private(set) var phase: Phase = .noDevice
    @Published private(set) var snapshot = StreamSession.Snapshot()
    @Published private(set) var screenRecordingGranted = CGPreflightScreenCaptureAccess()
    @Published private(set) var accessibilityGranted = AXIsProcessTrusted()
    @Published var scale: Double = {
        let v = UserDefaults.standard.double(forKey: "scale")
        return VirtualDisplay.scaleSteps.contains(v) ? v : 1.0
    }() {
        didSet {
            UserDefaults.standard.set(scale, forKey: "scale")
            session?.setScale(scale)
        }
    }
    @Published var paused = false {
        didSet { if paused { session?.stop(final: true) } }
    }
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled {
        didSet {
            guard launchAtLogin != (SMAppService.mainApp.status == .enabled) else { return }
            do {
                if launchAtLogin { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                Log.info("设置开机启动失败：\(error.localizedDescription)")
                launchAtLogin = SMAppService.mainApp.status == .enabled
            }
        }
    }
    /// iPad 当扩展屏、镜像 Mac 主屏，还是只用 iPad。iPad 工具条上也能切。
    @Published var displayMode = DisplayMode(rawValue: UserDefaults.standard.integer(forKey: "displayMode")) ?? .extend {
        didSet {
            UserDefaults.standard.set(displayMode.rawValue, forKey: "displayMode")
            session?.setMode(displayMode)
        }
    }
    @Published var hideCursorOnTouch = TouchCursor.enabled {
        didSet { TouchCursor.enabled = hideCursorOnTouch }
    }
    /// 无线会话进行中探测到的有线连接，等无线会话收尾后接手
    private var pendingWired: (MuxDevice, Int32)?

    /// 「随航竖屏」：借用系统随航的触控，Pivot 只负责把画面转成竖屏
    @Published private(set) var sidecarAvailable = SidecarPortrait.findSidecar() != nil
    @Published private(set) var sidecarPortrait = false
    @Published private(set) var sidecarStatus = ""
    @Published private(set) var sidecarClockwise = SidecarPortrait.clockwise

    func setSidecarPortrait(_ on: Bool) {
        let mode = SidecarPortrait.shared
        mode.onChange = { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.sidecarPortrait = mode.active
                self.sidecarStatus = mode.status
            }
        }
        if on {
            // 随航占着 iPad，Pivot 自己的连接先停掉
            session?.stop(final: true)
            mode.start()
        } else {
            mode.stop()
        }
        sidecarPortrait = mode.active
        sidecarStatus = mode.status
    }

    func flipSidecar() {
        SidecarPortrait.shared.flip()
        sidecarClockwise = SidecarPortrait.clockwise
    }

    @Published private(set) var pairedCount = PairingStore.pairedCount
    @Published private(set) var wirelessVisible = 0

    private let watcher = MuxWatcher()
    private let browser = WirelessBrowser()
    private let remote = RemoteListeners()
    /// 远程状态（菜单里显示）
    @Published private(set) var remoteStatus = ""
    private let probeQueue = DispatchQueue(label: "pivot.probe")
    private let wirelessQueue = DispatchQueue(label: "pivot.wireless", qos: .userInteractive)
    private var devices = Set<MuxDevice>()
    private var wirelessPeers: [WirelessPeer] = []
    private var wirelessAttempt: NWConnection?
    /// 上一次会话留下的虚拟显示器。短暂保留，换线或断线重连时窗口不必搬家。
    private var parkedDisplay: VirtualDisplay?
    private var parkGeneration = 0
    private var session: StreamSession?
    private var probing = false
    private var lastFailure: String?
    private var timer: Timer?

    private init() {}

    func start() {
        watcher.onAttach = { [weak self] device in
            DispatchQueue.main.async {
                Log.info("USB 设备接入：\(device.serial)")
                self?.devices.insert(device)
                self?.refreshPhase()
            }
        }
        watcher.onDetach = { [weak self] id in
            DispatchQueue.main.async {
                guard let self else { return }
                self.devices = self.devices.filter { $0.id != id }
                if self.session?.wiredDeviceID == id { self.session?.stop() }
                self.refreshPhase()
            }
        }
        watcher.start()
        browser.onChange = { [weak self] peers in
            DispatchQueue.main.async {
                guard let self else { return }
                self.wirelessPeers = peers
                // 只统计配对过的
                self.wirelessVisible = peers.filter { PairingStore.key(for: $0.deviceID) != nil }.count
                self.refreshPhase()
            }
        }
        browser.start()
        remote.onConnection = { [weak self] deviceID, connection in
            DispatchQueue.main.async { self?.handleRemote(deviceID: deviceID, connection: connection) }
        }
        remote.sync()
        refreshRemoteStatus()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private var tickCount = 0

    private func tick() {
        tickCount += 1
        if tickCount % 2 == 0 {
            let available = SidecarPortrait.findSidecar() != nil
            if available != sidecarAvailable { sidecarAvailable = available }
        }
        if sidecarPortrait { return }
        if let session {
            snapshot = session.snapshot()
            if session.isWireless, tickCount % 3 == 0 { probeWiredUpgrade() }
            if session.transport == .remote, tickCount % 4 == 0 { checkLocalUpgrade(session) }
        } else if tickCount % 2 == 0 {
            probe()
        }
        if tickCount % 4 == 0 {
            let screen = CGPreflightScreenCaptureAccess()
            let ax = AXIsProcessTrusted()
            if screen != screenRecordingGranted { screenRecordingGranted = screen }
            if ax != accessibilityGranted { accessibilityGranted = ax }
        }
    }

    private func refreshPhase() {
        let next: Phase
        if let session {
            next = session.snapshot().streaming ? .streaming : .connecting
        } else if let lastFailure {
            next = .failed(lastFailure)
        } else {
            next = devices.isEmpty && wirelessVisible == 0 ? .noDevice : .waitingForApp
        }
        if next != phase { phase = next }
    }

    /// 有线优先：逐个尝试已接入的 USB 设备（iPad 上的 Pivot 在前台时端口才会通）；
    /// 都不通再找配对过的无线设备。
    private func probe() {
        guard session == nil, !probing, !paused, wirelessAttempt == nil else { return }
        // 没有屏幕录制权限时连上也出不了画面，先让界面引导授权
        guard CGPreflightScreenCaptureAccess() else { return }
        // 测试开关：PIVOT_TRANSPORT=wireless 时即使插着线也只走无线
        // =wireless-first 时先用无线建立会话，之后允许自动升级到有线（用来测换线）
        let transport = ProcessInfo.processInfo.environment["PIVOT_TRANSPORT"]
        // =remote 时只接受 iPad 报到后回连（模拟两地），USB 和 Bonjour 都不用
        if transport == "remote" { return }
        let wirelessOnly = transport == "wireless" || transport == "wireless-first"
        let candidates = wirelessOnly ? [] : Array(devices)
        let peer = wirelessPeers.first { PairingStore.key(for: $0.deviceID) != nil }
        guard !candidates.isEmpty || peer != nil else { return }
        probing = true
        probeQueue.async { [weak self] in
            var found: (MuxDevice, Int32)?
            for device in candidates {
                if let fd = try? USBMux.connect(deviceID: device.id, port: Wire.port) {
                    found = (device, fd)
                    break
                }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.probing = false
                if let (device, fd) = found {
                    guard self.session == nil, !self.paused else { close(fd); return }
                    Log.info("已通过 USB 连上 \(device.serial)")
                    self.open(channel: FDChannel(fd: fd), wiredDeviceID: device.id)
                } else if let peer, self.session == nil, !self.paused {
                    self.connectWireless(peer)
                }
            }
        }
    }

    /// 无线用着的时候插上了线：有线更稳、延迟更低，自动换过去。
    /// 虚拟显示器会留给新会话接着用，窗口不动。
    private func probeWiredUpgrade() {
        guard !probing, !paused, pendingWired == nil, !devices.isEmpty,
              !["wireless", "remote"].contains(ProcessInfo.processInfo.environment["PIVOT_TRANSPORT"] ?? "") else { return }
        probing = true
        let candidates = Array(devices)
        probeQueue.async { [weak self] in
            var found: (MuxDevice, Int32)?
            for device in candidates {
                if let fd = try? USBMux.connect(deviceID: device.id, port: Wire.port) { found = (device, fd); break }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.probing = false
                guard let found else { return }
                guard let session = self.session, session.isWireless, !self.paused else { close(found.1); return }
                Log.info("检测到 USB 连接，从无线切换到有线")
                self.pendingWired = found
                session.stop()
            }
        }
    }

    /// iPad 经内嵌的 EasyTier 连了进来（两地之间，或者 Bonjour 还没来得及发现它）。
    /// 已有会话就拒绝；同一局域网里看得到它时，改走局域网直连。
    private func handleRemote(deviceID: String, connection: NWConnection) {
        let forceRemote = ProcessInfo.processInfo.environment["PIVOT_TRANSPORT"] == "remote"
        guard session == nil, !paused, CGPreflightScreenCaptureAccess() else { connection.cancel(); return }
        if !forceRemote, let local = wirelessPeers.first(where: { $0.deviceID == deviceID }) {
            connection.cancel()
            if wirelessAttempt == nil, !probing { connectWireless(local) }
            return
        }
        let name = PairingStore.name(for: deviceID) ?? "iPad"
        Log.info("\(name) 经远程组网连入（\(connection.endpoint)）")
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            DispatchQueue.main.async {
                guard let self, let connection else { return }
                switch state {
                case .ready:
                    connection.stateUpdateHandler = nil
                    guard self.session == nil, !self.paused else { connection.cancel(); return }
                    self.wirelessAttempt?.cancel()
                    self.wirelessAttempt = nil
                    self.open(channel: HybridChannel(inner: NWChannel(connection: connection, queue: self.remote.connectionQueue)), wiredDeviceID: nil, transport: .remote)
                case .failed(let e):
                    Log.info("远程连入握手失败：\(e.localizedDescription)")
                    connection.cancel()
                default: break
                }
            }
        }
        connection.start(queue: remote.connectionQueue)
    }

    private func refreshRemoteStatus() {
        DispatchQueue.global().async { [weak self] in
            let mesh = MeshDetector.detect()
            DispatchQueue.main.async {
                guard let self else { return }
                let ready = PairingStore.remoteDevices().count
                if let mesh {
                    self.remoteStatus = ready > 0 ? "远程已开启（EasyTier \(mesh.name)，本机 \(mesh.ip)）" : "插线连一次 iPad，即可开启远程"
                } else {
                    self.remoteStatus = "未检测到 EasyTier，远程不可用"
                }
            }
        }
    }

    /// 远程用着时，iPad 回到了同一局域网（Bonjour 看得到它）：换到局域网直连。显示器沿用，窗口不动。
    private func checkLocalUpgrade(_ session: StreamSession) {
        guard pendingWired == nil, ProcessInfo.processInfo.environment["PIVOT_TRANSPORT"] != "remote", let id = session.deviceID, wirelessPeers.contains(where: { $0.deviceID == id }) else { return }
        Log.info("iPad 回到了局域网，从远程切换到局域网直连")
        session.stop()
    }

    private func connectWireless(_ peer: WirelessPeer, transport: StreamSession.Transport = .local) {
        guard wirelessAttempt == nil, let key = PairingStore.key(for: peer.deviceID) else { return }
        let connection = NWConnection(to: peer.endpoint, using: Pairing.parameters(key: key))
        wirelessAttempt = connection
        var settled = false
        connection.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
                guard let self, !settled, self.wirelessAttempt === connection else { return }
                switch state {
                case .ready:
                    settled = true
                    self.wirelessAttempt = nil
                    guard self.session == nil, !self.paused else { connection.cancel(); return }
                    Log.info("已通过无线连上 \(peer.name)")
                    self.open(channel: HybridChannel(inner: NWChannel(connection: connection, queue: self.wirelessQueue)), wiredDeviceID: nil, transport: transport)
                case .failed(let error), .waiting(let error):
                    settled = true
                    Log.info("无线连接 \(peer.name) 未成功：\(error.localizedDescription)")
                    connection.cancel()
                    self.wirelessAttempt = nil
                case .cancelled:
                    settled = true
                    self.wirelessAttempt = nil
                default:
                    break
                }
            }
        }
        connection.start(queue: wirelessQueue)
        DispatchQueue.main.asyncAfter(deadline: .now() + (transport == .remote ? 10 : 6)) { [weak self] in
            guard let self, self.wirelessAttempt === connection else { return }
            connection.cancel()
            self.wirelessAttempt = nil
        }
    }

    private func open(channel: Channel, wiredDeviceID: Int?, transport: StreamSession.Transport? = nil) {
        lastFailure = nil
        parkGeneration += 1
        let adopt = parkedDisplay
        parkedDisplay = nil
        let session = StreamSession(channel: channel, wiredDeviceID: wiredDeviceID,
                                    transport: transport ?? (wiredDeviceID == nil ? .local : .wired),
                                    mode: displayMode, scale: scale, adopt: adopt)
        session.onModeRequest = { [weak self] m in self?.displayMode = m }
        // 有线时把远程组网参数交给 iPad
        session.meshFor = { deviceID in PairingStore.remotePort(for: deviceID).flatMap { MeshDetector.config(port: $0) } }
        session.onPairingKey = { [weak self] deviceID, key, name in
            if PairingStore.save(deviceID: deviceID, key: key, name: name) { Log.info("已与 \(name) 配对，之后可以无线连接") }
            self?.pairedCount = PairingStore.pairedCount
            self?.remote.sync()
            self?.refreshRemoteStatus()
        }
        session.onChanged = { [weak self] in
            DispatchQueue.main.async {
                guard let self, let s = self.session else { return }
                self.snapshot = s.snapshot()
                self.refreshPhase()
            }
        }
        session.onEnded = { [weak self, weak session] reason, display in
            guard let self, self.session === session else { return }
            self.session = nil
            self.snapshot = StreamSession.Snapshot()
            self.lastFailure = reason
            // iPad 是退到后台后断的：显示器留 5 分钟，等它回来接着用（窗口不乱跑）
            self.park(display, userInitiated: self.paused, seconds: session?.padPaused == true ? 300 : 5)
            if let (device, fd) = self.pendingWired {
                self.pendingWired = nil
                if self.paused { close(fd) } else {
                    self.open(channel: FDChannel(fd: fd), wiredDeviceID: device.id)
                    return
                }
            }
            self.refreshPhase()
            // 出错信息保留几秒后回到等待状态
            if reason != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
                    guard let self, self.session == nil else { return }
                    self.lastFailure = nil
                    self.refreshPhase()
                }
            }
            // 断开后马上找另一条路重连（比如拔线后转无线）
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.probe() }
        }
        self.session = session
        refreshPhase()
    }

    /// 会话结束后把显示器留几秒。期间同一台 iPad 重新连上（换了线路或只是闪断）就接着用。
    /// iPad 退到后台后断开的留 5 分钟；“仅 iPad”的 Mac 屏幕在会话结束时就已恢复，不会黑着等。
    private func park(_ display: VirtualDisplay?, userInitiated: Bool, seconds: Double = 5) {
        parkGeneration += 1
        guard let display, !userInitiated else { parkedDisplay = nil; return }
        parkedDisplay = display
        let generation = parkGeneration
        if seconds > 5 { Log.info("iPad 在后台：虚拟显示器保留 \(Int(seconds / 60)) 分钟") }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, self.parkGeneration == generation else { return }
            if seconds > 5 { Log.info("iPad 超过 \(Int(seconds / 60)) 分钟没回来，收起虚拟显示器") }
            self.parkedDisplay = nil
        }
    }

    func disconnect() {
        paused = true
    }

    /// 清掉所有配对。之后这些 iPad 要重新插线一次才能无线连接。
    func forgetPairings() {
        PairingStore.forgetAll()
        remote.sync()
        refreshRemoteStatus()
        pairedCount = 0
        wirelessVisible = 0
        if session?.isWireless == true { session?.stop(final: true) }
        refreshPhase()
    }

    // MARK: - 授权

    func requestScreenRecording() {
        if !CGRequestScreenCaptureAccess() {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        }
    }

    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(options) {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        }
    }
}
