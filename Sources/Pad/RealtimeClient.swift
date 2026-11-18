import Foundation

/// iPad 端的 UDP 实时通道：收画面分片拼帧，发触控（带冗余）和回执。
/// 每半秒报到一次（顺带回报收包和丢包），Mac 靠它知道往哪儿回、该加多少纠错。
final class RTClient {
    private let socket: RTSocket
    private let crypto: RTCrypto
    private let assembler = RTFrameAssembler()
    private let queue = DispatchQueue(label: "pivot.rt.client", qos: .userInteractive)
    private var replay = RTReplayWindow()
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

    /// queue 上回调
    var onFrame: ((RTFrameAssembler.Frame) -> Void)?
    var onLoss: ((Int) -> Void)?
    var onReady: (() -> Void)?
    var onAudio: ((Data) -> Void)?

    init?(host: String, port: UInt16, pairingKey: Data, salt: Data) {
        guard let socket = RTSocket(host: host, port: port) else { return nil }
        self.socket = socket
        crypto = RTCrypto(pairingKey: pairingKey, salt: salt, isHost: false)
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
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(500))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    private func tick() {
        assembler.expire()
        var hello = Data([RT.Kind.hello.rawValue])
        hello.appendLE(received); hello.appendLE(lost); hello.appendLE(lostFrames)
        received = 0; lost = 0; lostFrames = 0
        sendPlain(hello)
    }

    private func receive(_ data: Data) {
        guard let (s, plain) = crypto.open(data), replay.accept(s), let kindRaw = plain.first, let kind = RT.Kind(rawValue: kindRaw) else { return }
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

    private func sendPlain(_ plain: Data) {
        seq += 1
        if let packet = crypto.seal(seq: seq, plain) { socket.send(packet) }
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
    }
}
