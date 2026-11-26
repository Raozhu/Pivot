import Foundation

/// iPad 端的 UDP 实时通道：收画面分片拼帧，发触控（带冗余）和回执。
/// 每半秒报到一次（顺带回报收包和丢包），Mac 靠它知道往哪儿回、该加多少纠错。
final class RTClient {
    private let socket: RTSocket
    private let crypto: RTCrypto
    private let assembler = RTFrameAssembler()
    private let queue = DispatchQueue(label: "pivot.rt.client", qos: .userInteractive)
    private var replay = RTReplayWindow()
    private var probeReplay = RTReplayWindow()
    private var seq: UInt64 = 0
    private var timer: DispatchSourceTimer?
    private var lastHelloAck: UInt64 = 0

    // 统计（queue 上）
    private var highestSeen: UInt64 = 0
    private var received: UInt32 = 0
    private var lost: UInt32 = 0
    private var lostFrames: UInt32 = 0

    // 触控冗余（queue 上）
    private var touchSeq: UInt32 = 0
    private var recentTouches: [(seq: UInt32, payload: Data)] = []

    /// 远程直连（见 DirectPath）：打通后所有包都走它，不经 EasyTier
    private var direct: DirectLink?
    private var macCandidates: [String] = []
    private var directWasAlive = false
    private var ticks = 0
    /// 问到直连公网地址（要经控制连接告诉 Mac）。任意线程
    var onDirectCandidate: (([String]) -> Void)?

    /// queue 上回调
    var onFrame: ((RTFrameAssembler.Frame) -> Void)?
    var onLoss: ((Int) -> Void)?
    var onReady: (() -> Void)?
    var onAudio: ((Data) -> Void)?

    /// - Parameter directInterface: 远程时传物理网卡名（可为空串），打开直连；局域网传 nil
    init?(host: String, port: UInt16, pairingKey: Data, salt: Data, directInterface: String? = nil) {
        guard let socket = RTSocket(host: host, port: port) else { return nil }
        self.socket = socket
        crypto = RTCrypto(pairingKey: pairingKey, salt: salt, isHost: false)
        if let directInterface, let link = DirectLink(interface: directInterface) {
            direct = link
            let crypto = self.crypto
            link.makeProbe = { [weak link] in link.flatMap { crypto.seal(seq: $0.nextProbeSeq(), Data([RT.Kind.probe.rawValue])) } }
            link.onPublicAddr = { [weak self, weak link] _ in
                guard let link else { return }
                print("实时通道：直连候选 \(link.candidates)（网卡 \(directInterface.isEmpty ? "默认" : directInterface)）")
                self?.onDirectCandidate?(link.candidates)
            }
            link.socket.onPacket = { [weak self, weak link] data, from in
                guard let self, let link, !link.handleSTUN(data) else { return }
                self.queue.async { self.receive(data, from: from, viaDirect: true) }
            }
        }
        assembler.onFrame = { [weak self] f in self?.onFrame?(f) }
        assembler.onLoss = { [weak self] n in
            guard let self else { return }
            self.lostFrames &+= UInt32(n)
            self.onLoss?(n)
        }
        socket.onPacket = { [weak self] data, _ in
            guard let self else { return }
            self.queue.async { self.receive(data) }
        }
    }

    /// Mac 最近 3 秒内回过报到，才把触控和回执交给 UDP
    var ready: Bool { queue.sync { lastHelloAck != 0 && monotonicNs() - lastHelloAck < 3_000_000_000 } }

    func start() {
        socket.start()
        if let direct { direct.socket.start(); direct.start() }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(500))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    /// Mac 报来的直连地址（任意线程）
    func addDirectCandidates(_ addrs: [String]) {
        queue.async { [self] in
            macCandidates = addrs
            direct?.addPeerCandidates(addrs)
        }
    }

    private func tick() {
        assembler.expire()
        if let direct {
            ticks += 1
            let alive = direct.alive
            if alive != directWasAlive {
                directWasAlive = alive
                print(alive ? "实时通道：远程直连已打通" : "实时通道：直连断了，退回组网")
            }
            // 没通的时候每 10 秒重新打一次洞，并把自己的地址再报一遍（Mac 那边也会重打）
            if !alive, ticks % 20 == 0, !macCandidates.isEmpty {
                direct.addPeerCandidates(macCandidates)
                let c = direct.candidates
                if !c.isEmpty { onDirectCandidate?(c) }
            }
        }
        var hello = Data([RT.Kind.hello.rawValue])
        hello.appendLE(received); hello.appendLE(lost); hello.appendLE(lostFrames)
        received = 0; lost = 0; lostFrames = 0
        sendPlain(hello)
    }

    private func receive(_ data: Data, from: sockaddr_storage? = nil, viaDirect: Bool = false) {
        guard let (s, plain) = crypto.open(data), let kindRaw = plain.first, let kind = RT.Kind(rawValue: kindRaw) else { return }
        // 探测包走自己的序号段：不进丢包统计
        if DirectPath.isProbeSeq(s) {
            guard viaDirect, let from, let direct, probeReplay.accept(s) else { return }
            direct.heard(from: from)
            if kind == .probe, let reply = crypto.seal(seq: direct.nextProbeSeq(), Data([RT.Kind.probeAck.rawValue])) { direct.socket.send(reply, to: from) }
            return
        }
        guard replay.accept(s) else { return }
        if viaDirect, let from { direct?.heard(from: from) }
        received &+= 1
        if s > highestSeen {
            if highestSeen != 0, s - highestSeen > 1 { lost &+= UInt32(min(1000, s - highestSeen - 1)) }
            highestSeen = s
        }
        switch kind {
        case .video:
            if let shard = RTShard.decode(plain.dropFirst()) { assembler.add(shard) }
        case .audio:
            onAudio?(Data(plain.dropFirst()))
        case .helloAck:
            let first = lastHelloAck == 0
            lastHelloAck = monotonicNs()
            if first { onReady?() }
        default:
            break
        }
    }

    private func sealNext(_ plain: Data) -> Data? {
        seq += 1
        return crypto.seal(seq: seq, plain)
    }

    private func sendPlain(_ plain: Data) {
        guard let packet = sealNext(plain) else { return }
        if let direct, let to = direct.peerAddr { direct.socket.send(packet, to: to) } else { socket.send(packet) }
    }

    /// 触控：每包捎带前两包。按下、抬起这类关键事件再补发两次
    func sendTouch(_ payload: Data, critical: Bool) {
        queue.async { [self] in
            touchSeq &+= 1
            recentTouches.append((touchSeq, payload))
            if recentTouches.count > 3 { recentTouches.removeFirst() }
            let packet = RTTouch.encode(recentTouches)
            sendPlain(packet)
            if critical {
                queue.asyncAfter(deadline: .now() + .milliseconds(5)) { self.sendPlain(packet) }
                queue.asyncAfter(deadline: .now() + .milliseconds(15)) { self.sendPlain(packet) }
            }
        }
    }

    func sendKeyframeRequest(_ payload: Data) {
        queue.async { [self] in sendPlain(Data([RT.Kind.keyframeRequest.rawValue]) + payload) }
    }

    func sendAck(_ payload: Data) {
        queue.async { [self] in
            var d = Data([RT.Kind.ack.rawValue])
            d.append(payload)
            sendPlain(d)
        }
    }

    func close() {
        timer?.cancel()
        timer = nil
        socket.close()
        direct?.close()
    }
}
