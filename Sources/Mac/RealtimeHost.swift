import Foundation

/// Mac 端的 UDP 实时通道：发画面分片、收触控和回执。iPad 先报到，Mac 才知道往哪儿回。
final class RTHost {
    let port: UInt16
    private let crypto: RTCrypto
    private let socket: RTSocket
    private let lock = NSLock()
    private var peer: sockaddr_storage?
    private var lastPeerNs: UInt64 = 0
    private var replay = RTReplayWindow()
    private var probeReplay = RTReplayWindow()
    private var seq: UInt64 = 0
    private var lastTouchSeq: UInt32 = 0
    private var touchLog: [(arrival: UInt64, padTs: UInt64)] = []
    private let sendQueue = DispatchQueue(label: "pivot.rt.send", qos: .userInteractive)
    private var pendingFrames = 0
    private var closed = false
    /// 远程直连（见 DirectPath）。peerViaDirect：当前对端地址是不是从直连套接字来的
    private var direct: DirectLink?
    private var peerViaDirect = false

    /// 纠错片比例，按 iPad 回报的丢包率自动调
    private(set) var parityRatio = 0.12
    /// 平滑发送速率（比特/秒）：不把一整帧瞬间灌进 Wi‑Fi 队列
    private var paceBps = 40_000_000.0

    var onTouch: ((Data) -> Void)?
    var onAck: ((Data) -> Void)?
    /// 负载同 TCP 的关键帧请求（1 字节：1 表示刷新即可）
    var onKeyframeRequest: ((Data) -> Void)?
    /// iPad 每 0.5 秒回报的包丢失率（0～1）
    var onLossRate: ((Double) -> Void)?
    /// iPad 回报：丢掉的帧数
    var onLoss: ((Int) -> Void)?
    var onFrameSent: (() -> Void)?
    var onPeer: ((String) -> Void)?

    init?(port: UInt16, pairingKey: Data, salt: Data) {
        guard let socket = RTSocket(listenPort: port) else { return nil }
        self.port = port
        self.socket = socket
        crypto = RTCrypto(pairingKey: pairingKey, salt: salt, isHost: true)
        socket.onPacket = { [weak self] data, from in self?.receive(data, from: from) }
        socket.start()
    }

    /// 最近 3 秒内收到过 iPad 的包，才走 UDP
    var active: Bool {
        lock.lock(); defer { lock.unlock() }
        return peer != nil && monotonicNs() - lastPeerNs < 3_000_000_000 && !closed
    }

    var backlog: Int { lock.lock(); defer { lock.unlock() }; return pendingFrames }

    /// 是否远程：决定发送节奏
    var remote = false

    func setBitrate(_ bps: Int) {
        lock.lock()
        // 发送速率留足余量：关键帧和纠错片都要能很快发完，又不至于一下子塞满队列
        // 远程：一串包太猛会在组网网卡和家用 Wi‑Fi 的队列里整串丢，放缓到 16 Mbps 起步（120 ms 内仍能送完约 240 KB）
        paceBps = remote ? max(8_000_000, Double(bps) * 3) : max(30_000_000, Double(bps) * 3)
        lock.unlock()
    }

    // MARK: 收

    private func receive(_ data: Data, from: sockaddr_storage, viaDirect: Bool = false) {
        guard let (seqIn, plain) = crypto.open(data), let kindRaw = plain.first, let kind = RT.Kind(rawValue: kindRaw) else { return }
        lock.lock()
        let isProbe = DirectPath.isProbeSeq(seqIn)
        guard isProbe ? probeReplay.accept(seqIn) : replay.accept(seqIn) else { lock.unlock(); return }
        // 探测包只用来打洞和确认直连，不改变往哪儿发
        if isProbe {
            let d = direct
            lock.unlock()
            if viaDirect { d?.heard(from: from) }
            if kind == .probe, let d, let reply = crypto.seal(seq: d.nextProbeSeq(), Data([RT.Kind.probeAck.rawValue])) {
                (viaDirect ? d.socket : socket).send(reply, to: from)
            }
            return
        }
        let isNew = peer.map { !$0.sameEndpoint(from) } ?? true
        let wasDirect = peerViaDirect
        peer = from
        peerViaDirect = viaDirect
        lastPeerNs = monotonicNs()
        let d = direct
        lock.unlock()
        if viaDirect { d?.heard(from: from) }
        if isNew { onPeer?(from.debugDescription) }
        if wasDirect != viaDirect {
            Log.info(viaDirect ? "实时通道：远程直连已打通（\(from.debugDescription)），画面改走直连 UDP" : "实时通道：直连断了，退回组网")
            onDirectChange?(viaDirect)
        }
        let body = plain.dropFirst()
        switch kind {
        case .hello:
            send(Data([RT.Kind.helloAck.rawValue]))
            if body.count >= 12 {
                let lostFrames = Int(body.readLE(UInt32.self, at: 8))
                let received = Double(body.readLE(UInt32.self, at: 0)), lost = Double(body.readLE(UInt32.self, at: 4))
                let rate = received + lost > 0 ? lost / (received + lost) : 0
                if rate >= 0.03 || lostFrames > 0 {
                    Log.info(String(format: "实时通道：iPad 回报丢包 %.0f%%（收 %.0f 丢 %.0f），丢帧 %d", rate * 100, received, lost, lostFrames))
                }
                adaptParity(lossRate: rate)
                if received + lost >= 20 { onLossRate?(rate) }
                if lostFrames > 0 { onLoss?(lostFrames) }
            }
        case .touch:
            let now = monotonicNs()
            var fresh: [(UInt32, Data)] = []
            lock.lock()
            for item in RTTouch.decode(Data(body)).sorted(by: { $0.seq < $1.seq }) where Int32(bitPattern: item.seq &- lastTouchSeq) > 0 || lastTouchSeq == 0 {
                lastTouchSeq = item.seq
                fresh.append(item)
                if item.payload.count >= 8 { touchLog.append((now, item.payload.readLE(UInt64.self, at: 0))) }
            }
            if touchLog.count > 64 { touchLog.removeFirst(touchLog.count - 64) }
            lock.unlock()
            for (_, payload) in fresh { onTouch?(payload) }
        case .ack:
            onAck?(Data(body))
        case .keyframeRequest:
            onKeyframeRequest?(Data(body))
        default:
            break
        }
    }

    /// 丢包越多纠错越多：大约是丢包率的 3 倍，10%～40%
    private func adaptParity(lossRate: Double) {
        lock.lock()
        let target = min(0.4, max(0.1, lossRate * 3 + 0.08))
        parityRatio = parityRatio * 0.6 + target * 0.4
        lock.unlock()
    }

    /// 某个采集时刻之前 Mac 已收到的最新触控的 iPad 时间戳。
    /// 多留 4 毫秒：触控注入后应用还要重绘，画面才会反映出来
    private func touchTs(before captureNs: UInt64) -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        let limit = captureNs > 4_000_000 ? captureNs - 4_000_000 : 0
        return touchLog.last(where: { $0.arrival <= limit })?.padTs ?? 0
    }

    // MARK: 发

    private func send(_ plain: Data) {
        lock.lock()
        guard let peer, !closed else { lock.unlock(); return }
        seq += 1
        let s = seq
        let out = peerViaDirect ? (direct?.socket ?? socket) : socket
        lock.unlock()
        if let packet = crypto.seal(seq: s, plain) { out.send(packet, to: peer) }
    }

    /// 直连通了 / 断了（读线程）
    var onDirectChange: ((Bool) -> Void)?
    /// 问到了直连套接字的公网地址，要经控制连接告诉 iPad
    var onDirectCandidate: (([String]) -> Void)?

    /// 当前画面走的是直连
    var peerIsDirect: Bool { lock.lock(); defer { lock.unlock() }; return peerViaDirect && peer != nil && monotonicNs() - lastPeerNs < 3_000_000_000 }

    /// 远程时打开直连：绑在物理网卡上，问公网地址，等 iPad 报来它的地址后打洞
    func enableDirect() {
        let iface = DirectPath.physicalInterface()
        guard let link = DirectLink(interface: iface) else { Log.info("实时通道：直连套接字开不了"); return }
        link.makeProbe = { [weak self, weak link] in
            guard let self, let link else { return nil }
            return self.crypto.seal(seq: link.nextProbeSeq(), Data([RT.Kind.probe.rawValue]))
        }
        link.onPublicAddr = { [weak self, weak link] a in
            guard let link else { return }
            Log.info("实时通道：直连候选 \(link.candidates.joined(separator: ", "))（网卡 \(iface ?? "默认")）")
            self?.onDirectCandidate?(link.candidates)
        }
        link.socket.onPacket = { [weak self, weak link] data, from in
            guard let self, let link else { return }
            if link.handleSTUN(data) { return }
            self.receive(data, from: from, viaDirect: true)
        }
        lock.lock(); direct = link; lock.unlock()
        link.socket.start()
        link.start()
    }

    func addDirectCandidates(_ addrs: [String]) {
        lock.lock(); let d = direct; lock.unlock()
        d?.addPeerCandidates(addrs)
    }

    /// 声音包小而频繁，直接发，不排在画面后面
    func sendAudio(_ payload: Data) {
        var d = Data([RT.Kind.audio.rawValue])
        d.append(payload)
        send(d)
    }

    func sendFrame(header: VideoHeader, data: Data, format: Data?) {
        let ts = touchTs(before: header.captureNs)
        lock.lock()
        pendingFrames += 1
        let ratio = parityRatio
        lock.unlock()
        let shards = RTShard.make(frame: header.index, isKey: header.isKey, isRefresh: header.isRefresh, captureNs: header.captureNs, touchTs: ts,
                                  blob: RTShard.frameBlob(format: format, data: data), parityRatio: ratio)
        sendQueue.async { [self] in
            // 令牌桶：允许约 24 KB 的突发，超出部分按速率平滑发出
            var tokens = 24_000.0
            var last = monotonicNs()
            for shard in shards {
                let plain = shard.encode()
                let now = monotonicNs()
                lock.lock(); let rate = paceBps / 8; lock.unlock()
                tokens = min(24_000, tokens + Double(now - last) / 1e9 * rate)
                last = now
                // 欠账不到 1 ms 就先发：每片都去睡零点几毫秒，系统一合并定时器整帧就被拖成几百毫秒。
                // iPad 端 120 ms 内拼不齐会整帧放弃，所以宁可小突发，也不能拖
                let wait = (Double(plain.count) - tokens) / rate
                if wait > 0.001 {
                    usleep(useconds_t(wait * 1e6))
                    let after = monotonicNs()
                    tokens += Double(after - last) / 1e9 * rate
                    last = after
                }
                tokens -= Double(plain.count)
                // 测试开关：PIVOT_RT_DROP=0.05 按比例随机丢视频分片，用来验证丢帧恢复
                if Self.testDrop > 0, Double.random(in: 0..<1) < Self.testDrop { continue }
                send(plain)
            }
            lock.lock(); pendingFrames -= 1; lock.unlock()
            onFrameSent?()
        }
    }

    private static let testDrop = Double(ProcessInfo.processInfo.environment["PIVOT_RT_DROP"] ?? "") ?? 0

    func close() {
        lock.lock()
        guard !closed else { lock.unlock(); return }
        closed = true
        let d = direct
        lock.unlock()
        socket.close()
        d?.close()
    }
}

/// 无线会话的通道：控制消息走 TLS 连接；iPad 支持且 UDP 通了以后，画面、触控和回执改走 UDP 实时通道。
/// UDP 断了（3 秒没收到 iPad 的包）自动退回 TLS 连接，画面不中断。
final class HybridChannel: Channel {
    private let inner: NWChannel
    private var rt: RTHost?
    private let lock = NSLock()
    private var latestFormat: Data?

    var onMessage: ((MsgType, Data) -> Void)?
    var onClose: (() -> Void)?
    var onVideoSent: (() -> Void)?
    /// iPad 回报有帧补不回来（会话据此降码率）
    var onRealtimeLoss: ((Int) -> Void)?
    var onLossRate: ((Double) -> Void)?

    init(inner: NWChannel) {
        self.inner = inner
        inner.onMessage = { [weak self] t, p in self?.onMessage?(t, p) }
        inner.onClose = { [weak self] in self?.rt?.close(); self?.onClose?() }
        inner.onVideoSent = { [weak self] in self?.onVideoSent?() }
    }

    func start() { inner.start() }

    /// 打开 UDP 实时通道，返回要发给 iPad 的参数
    func enableRealtime(port: UInt16, pairingKey: Data) -> RT.Offer? {
        let salt = Pairing.generateKey().prefix(16)
        guard let host = RTHost(port: port, pairingKey: pairingKey, salt: Data(salt)) else {
            Log.info("实时通道：UDP 端口 \(port) 打不开，继续走 TCP")
            return nil
        }
        host.remote = remote
        host.onTouch = { [weak self] p in self?.onMessage?(.touch, p) }
        host.onAck = { [weak self] p in self?.onMessage?(.ack, p) }
        host.onKeyframeRequest = { [weak self] p in self?.onMessage?(.keyframeRequest, p) }
        host.onLossRate = { [weak self] r in self?.onLossRate?(r) }
        host.onLoss = { [weak self] n in self?.onRealtimeLoss?(n) }
        host.onFrameSent = { [weak self] in self?.onVideoSent?() }
        host.onPeer = { addr in Log.info("实时通道：iPad 已从 \(addr) 接入 UDP") }
        host.onDirectChange = { [weak self] d in self?.onDirectChange?(d) }
        host.onDirectCandidate = { [weak self] a in self?.onDirectCandidate?(a) }
        lock.lock(); rt = host; lock.unlock()
        return RT.Offer(port: port, salt: Data(salt).base64EncodedString())
    }

    /// 画面和声音是否也走 UDP。远程时为 false：iPad 的组网是用户态转发，大块 UDP 一突发就丢，
    /// 画面留在 TCP；触控和回执包小、量少，走 UDP 才不会被 TCP 的攒包（Nagle / 延迟确认）攒成一坨
    var videoOverRealtime = true

    /// 画面走 UDP：局域网时一直走；远程时只有直连打通了才走（不经 iPad 上的 EasyTier）
    private var videoOnRT: Bool {
        guard let rt, rt.active else { return false }
        return videoOverRealtime || rt.peerIsDirect
    }

    /// 画面正走 UDP（会真丢帧、需要补关键帧）
    var realtimeActive: Bool { lock.lock(); defer { lock.unlock() }; return videoOnRT }

    /// 直连通断（会话据此切码率策略）
    var onDirectChange: ((Bool) -> Void)?
    /// 要经控制连接发给 iPad 的直连候选
    var onDirectCandidate: (([String]) -> Void)?

    func enableDirect() { lock.lock(); let r = rt; lock.unlock(); r?.enableDirect() }
    func addDirectCandidates(_ addrs: [String]) { lock.lock(); let r = rt; lock.unlock(); r?.addDirectCandidates(addrs) }

    func setBitrate(_ bps: Int) { lock.lock(); let r = rt; lock.unlock(); r?.setBitrate(bps) }
    var remote = false

    var videoBacklog: Int {
        lock.lock(); let r = rt; lock.unlock()
        if let r, videoOnRT { return r.backlog }
        return inner.videoBacklog
    }

    func send(_ type: MsgType, _ payload: Data) {
        if type == .format { lock.lock(); latestFormat = payload; lock.unlock() }
        if type == .audio {
            lock.lock(); let r = rt; lock.unlock()
            if let r, videoOnRT { r.sendAudio(payload); return }
        }
        inner.send(type, payload)
    }

    func sendVideo(header: VideoHeader, data: Data) {
        lock.lock(); let r = rt; let format = latestFormat; lock.unlock()
        if let r, videoOnRT {
            // 关键帧带上参数集：UDP 和 TCP 不保证先后，自带参数集才能保证解得出来
            r.sendFrame(header: header, data: data, format: header.isKey ? format : nil)
        } else {
            inner.sendVideo(header: header, data: data)
        }
    }

    func close() {
        lock.lock(); let r = rt; lock.unlock()
        r?.close()
        inner.close()
    }
}
