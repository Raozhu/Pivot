import Foundation
import CryptoKit
import Darwin

/// 无线时的 UDP 实时通道：画面和触控走这里，控制消息仍走 TLS 连接。
///
/// TCP 要求按顺序全部送达，网络一抖或丢一个包，后面所有画面和触控都得排队等它重传。
/// 这里每帧切成小包、附带异或纠错包，补不回来的帧直接放弃（再要一个关键帧），绝不让旧帧挡住新帧；
/// 触控包每次捎带前两包，丢一包也不影响轨迹。
///
/// 加密：用配对密钥和每次会话的随机盐派生两个方向各自的密钥（ChaCha20‑Poly1305），包序号做随机数并防重放。
enum RT {
    /// 每个视频分片的数据字节数。加上头部、认证标签和 EasyTier 的封装后仍在 1280 字节以内，避免分片
    static let shardSize = 1100
    /// 握手里 Mac 发给 iPad 的 UDP 参数
    struct Offer: Codable {
        var port: UInt16
        var salt: String
    }

    enum Kind: UInt8 {
        case hello = 1      // pad → mac：报到 / 保活（也让 Mac 知道往哪儿回）
        case video = 2      // mac → pad：一个视频分片
        case touch = 3      // pad → mac：触控（含冗余）
        case ack = 4        // pad → mac：和 TCP 的 ack 相同的负载
        case stats = 5      // pad → mac：u32 收到包数 + u32 丢包数 + u32 丢帧数
        case helloAck = 6   // mac → pad：收到报到
        case audio = 7      // mac → pad：和 TCP 的 audio 相同的负载
    }
}

// MARK: - 加密

struct RTCrypto {
    private let sendKey: SymmetricKey
    private let recvKey: SymmetricKey

    init(pairingKey: Data, salt: Data, isHost: Bool) {
        let master = SymmetricKey(data: pairingKey)
        func derive(_ info: String) -> SymmetricKey {
            HKDF<SHA256>.deriveKey(inputKeyMaterial: master, salt: salt, info: Data(info.utf8), outputByteCount: 32)
        }
        let toPad = derive("pivot-rt mac->pad"), toMac = derive("pivot-rt pad->mac")
        sendKey = isHost ? toPad : toMac
        recvKey = isHost ? toMac : toPad
    }

    private static func nonce(_ seq: UInt64) -> ChaChaPoly.Nonce {
        var bytes = [UInt8](repeating: 0, count: 12)
        withUnsafeBytes(of: seq.littleEndian) { for i in 0..<8 { bytes[4 + i] = $0[i] } }
        return try! ChaChaPoly.Nonce(data: bytes)
    }

    /// 包格式：u64 序号 + 密文 + 16 字节认证标签
    func seal(seq: UInt64, _ plain: Data) -> Data? {
        guard let box = try? ChaChaPoly.seal(plain, using: sendKey, nonce: Self.nonce(seq)) else { return nil }
        var out = Data(capacity: 8 + plain.count + 16)
        out.appendLE(seq)
        out.append(box.ciphertext)
        out.append(box.tag)
        return out
    }

    func open(_ packet: Data) -> (seq: UInt64, plain: Data)? {
        guard packet.count >= 8 + 1 + 16 else { return nil }
        let seq = packet.readLE(UInt64.self, at: 0)
        let s = packet.startIndex
        guard let box = try? ChaChaPoly.SealedBox(nonce: Self.nonce(seq),
                                                  ciphertext: packet[(s + 8)..<(packet.endIndex - 16)],
                                                  tag: packet[(packet.endIndex - 16)...]),
              let plain = try? ChaChaPoly.open(box, using: recvKey) else { return nil }
        return (seq, plain)
    }
}

/// 防重放：记住最大序号和它之前 64 个序号收没收过
struct RTReplayWindow {
    private var highest: UInt64 = 0
    private var bitmap: UInt64 = 0
    private var started = false

    mutating func accept(_ seq: UInt64) -> Bool {
        if !started { started = true; highest = seq; bitmap = 1; return true }
        if seq > highest {
            let shift = seq - highest
            bitmap = shift >= 64 ? 1 : (bitmap << shift) | 1
            highest = seq
            return true
        }
        let back = highest - seq
        guard back < 64 else { return false }
        let bit: UInt64 = 1 << back
        if bitmap & bit != 0 { return false }
        bitmap |= bit
        return true
    }

    /// 累计看到的序号空洞（估算丢包）用：返回本包之前跳过了几个序号
    var top: UInt64 { highest }
}

// MARK: - 视频分片与纠错

/// 一个视频分片。一帧的数据（含可选的参数集）切成若干等长数据片，再按交错分组生成异或纠错片：
/// 纠错片 j 覆盖序号 i % parity == j 的数据片，所以连续丢 parity 个以内的包都能补回。
struct RTShard {
    static let headerSize = 4 + 1 + 8 + 8 + 2 + 2 + 2 + 4
    var frame: UInt32
    var isKey: Bool
    var captureNs: UInt64
    /// 这一帧采集前，Mac 已收到的最新触控的 iPad 时间戳（纳秒，0 表示没有）
    var touchTs: UInt64
    var index: UInt16
    var dataCount: UInt16
    var parityCount: UInt16
    /// 帧数据总长（含参数集前缀）
    var frameLength: UInt32
    var payload: Data

    func encode() -> Data {
        var d = Data(capacity: 1 + Self.headerSize + payload.count)
        d.append(RT.Kind.video.rawValue)
        d.appendLE(frame); d.append(isKey ? 1 : 0); d.appendLE(captureNs); d.appendLE(touchTs)
        d.appendLE(index); d.appendLE(dataCount); d.appendLE(parityCount); d.appendLE(frameLength)
        d.append(payload)
        return d
    }

    /// `body` 不含类型字节
    static func decode(_ body: Data) -> RTShard? {
        var r = ByteReader(body)
        guard let f: UInt32 = r.read(), let k: UInt8 = r.read(), let c: UInt64 = r.read(), let t: UInt64 = r.read(),
              let i: UInt16 = r.read(), let dc: UInt16 = r.read(), let pc: UInt16 = r.read(), let len: UInt32 = r.read(),
              dc > 0, i < dc &+ pc else { return nil }
        return RTShard(frame: f, isKey: k & 1 == 1, captureNs: c, touchTs: t, index: i, dataCount: dc, parityCount: pc,
                       frameLength: len, payload: body.subdata(in: (body.startIndex + headerSize)..<body.endIndex))
    }

    /// 帧数据 = u32 参数集长度 + 参数集 + 视频数据
    static func frameBlob(format: Data?, data: Data) -> Data {
        var blob = Data(capacity: 4 + (format?.count ?? 0) + data.count)
        blob.appendLE(UInt32(format?.count ?? 0))
        if let format { blob.append(format) }
        blob.append(data)
        return blob
    }

    static func splitBlob(_ blob: Data) -> (format: Data?, data: Data)? {
        guard blob.count >= 4 else { return nil }
        let n = Int(blob.readLE(UInt32.self, at: 0))
        guard blob.count >= 4 + n else { return nil }
        let s = blob.startIndex + 4
        return (n > 0 ? blob.subdata(in: s..<(s + n)) : nil, blob.subdata(in: (s + n)..<blob.endIndex))
    }

    /// 把一帧切成数据片 + 纠错片
    static func make(frame: UInt32, isKey: Bool, captureNs: UInt64, touchTs: UInt64, blob: Data, parityRatio: Double) -> [RTShard] {
        let size = RT.shardSize
        let dataCount = max(1, (blob.count + size - 1) / size)
        // 小帧至少一片纠错；关键帧多给一些，丢了代价最大
        let ratio = isKey ? max(parityRatio, 0.2) : parityRatio
        let parityCount = min(dataCount, max(1, Int((Double(dataCount) * ratio).rounded(.up))))
        var shards: [RTShard] = []
        shards.reserveCapacity(dataCount + parityCount)
        var parity = [[UInt8]](repeating: [UInt8](repeating: 0, count: size), count: parityCount)
        blob.withUnsafeBytes { raw in
            let base = raw.bindMemory(to: UInt8.self)
            for i in 0..<dataCount {
                let start = i * size, end = min(blob.count, start + size)
                var chunk = [UInt8](repeating: 0, count: size)
                for j in start..<end { chunk[j - start] = base[j] }
                let p = i % parityCount
                for j in 0..<size { parity[p][j] ^= chunk[j] }
                shards.append(RTShard(frame: frame, isKey: isKey, captureNs: captureNs, touchTs: touchTs, index: UInt16(i),
                                      dataCount: UInt16(dataCount), parityCount: UInt16(parityCount),
                                      frameLength: UInt32(blob.count), payload: Data(chunk[0..<(end - start)])))
            }
        }
        for p in 0..<parityCount {
            shards.append(RTShard(frame: frame, isKey: isKey, captureNs: captureNs, touchTs: touchTs, index: UInt16(dataCount + p),
                                  dataCount: UInt16(dataCount), parityCount: UInt16(parityCount),
                                  frameLength: UInt32(blob.count), payload: Data(parity[p])))
        }
        return shards
    }
}

/// iPad 端：把分片拼回整帧。补不回来的帧直接放弃，绝不阻塞后面的帧。
final class RTFrameAssembler {
    struct Frame {
        var index: UInt32
        var isKey: Bool
        var captureNs: UInt64
        var touchTs: UInt64
        var format: Data?
        var data: Data
    }

    private struct Partial {
        var dataCount: Int
        var parityCount: Int
        var frameLength: Int
        var isKey: Bool
        var captureNs: UInt64
        var touchTs: UInt64
        var data: [Data?]
        var parity: [Data?]
        var received = 0
        var firstNs: UInt64
    }

    private var partials: [UInt32: Partial] = [:]
    private var lastDelivered: UInt32?
    /// 超过这个时间还没拼齐就放弃
    var deadlineNs: UInt64 = 120_000_000

    var onFrame: ((Frame) -> Void)?
    /// 有帧补不回来、被放弃（参数：被放弃的帧数）
    var onLoss: ((Int) -> Void)?

    private func isOlder(_ a: UInt32, than b: UInt32) -> Bool { Int32(bitPattern: a &- b) < 0 }

    func add(_ s: RTShard) {
        let now = monotonicNs()
        if let last = lastDelivered, !isOlder(last, than: s.frame) { return }  // 已交付或已放弃
        var p = partials[s.frame] ?? Partial(dataCount: Int(s.dataCount), parityCount: Int(s.parityCount), frameLength: Int(s.frameLength),
                                             isKey: s.isKey, captureNs: s.captureNs, touchTs: s.touchTs,
                                             data: Array(repeating: nil, count: Int(s.dataCount)),
                                             parity: Array(repeating: nil, count: Int(s.parityCount)), firstNs: now)
        guard p.dataCount == Int(s.dataCount), p.parityCount == Int(s.parityCount) else { return }
        let i = Int(s.index)
        if i < p.dataCount {
            if p.data[i] == nil { p.data[i] = s.payload; p.received += 1 }
        } else if p.parity[i - p.dataCount] == nil {
            p.parity[i - p.dataCount] = s.payload
            p.received += 1
        }
        partials[s.frame] = p
        if let blob = tryAssemble(&partials[s.frame]!) {
            deliver(s.frame, blob: blob, partial: partials[s.frame]!)
        }
        expire(now: now)
    }

    /// 定时调用：把超时的半成品放弃掉
    func expire(now: UInt64 = monotonicNs()) {
        var lost = 0
        for (k, p) in partials where now - p.firstNs > deadlineNs {
            partials[k] = nil
            if lastDelivered == nil || isOlder(lastDelivered!, than: k) { lastDelivered = k }
            lost += 1
        }
        if lost > 0 { onLoss?(lost) }
    }

    private func tryAssemble(_ p: inout Partial) -> Data? {
        let missing = p.data.indices.filter { p.data[$0] == nil }
        if !missing.isEmpty {
            // 每个交错组最多补回一个缺片
            for m in missing {
                let g = m % p.parityCount
                guard let par = p.parity[g] else { return nil }
                let group = stride(from: g, to: p.dataCount, by: p.parityCount)
                guard group.filter({ p.data[$0] == nil }).count == 1 else { return nil }
                var rec = [UInt8](par)
                for j in group where j != m {
                    p.data[j]!.withUnsafeBytes { b in for x in 0..<b.count { rec[x] ^= b[x] } }
                }
                let len = m == p.dataCount - 1 ? p.frameLength - m * RT.shardSize : RT.shardSize
                p.data[m] = Data(rec[0..<len])
            }
        }
        var blob = Data(capacity: p.frameLength)
        for d in p.data { blob.append(d!) }
        return blob.count == p.frameLength ? blob : nil
    }

    private func deliver(_ index: UInt32, blob: Data, partial p: Partial) {
        // 比它旧、还没拼齐的帧都放弃
        var lost = 0
        for k in partials.keys where isOlder(k, than: index) { partials[k] = nil; lost += 1 }
        if let last = lastDelivered, index &- last > 1 { lost = max(lost, Int(index &- last) - 1) }
        partials[index] = nil
        lastDelivered = index
        if lost > 0 { onLoss?(lost) }
        guard let (format, data) = RTShard.splitBlob(blob) else { return }
        onFrame?(Frame(index: index, isKey: p.isKey, captureNs: p.captureNs, touchTs: p.touchTs, format: format, data: data))
    }

    func reset() { partials.removeAll(); lastDelivered = nil }
}

// MARK: - 触控冗余

/// 每个触控包附带前两包，丢一包也不影响轨迹；Mac 按序号去重
enum RTTouch {
    static func encode(_ items: [(seq: UInt32, payload: Data)]) -> Data {
        var d = Data()
        d.append(RT.Kind.touch.rawValue)
        d.append(UInt8(items.count))
        for item in items {
            d.appendLE(item.seq)
            d.appendLE(UInt16(item.payload.count))
            d.append(item.payload)
        }
        return d
    }

    static func decode(_ body: Data) -> [(seq: UInt32, payload: Data)] {
        var out: [(UInt32, Data)] = []
        guard let n = body.first else { return out }
        var at = body.startIndex + 1
        for _ in 0..<n {
            guard body.endIndex - at >= 6 else { break }
            let seq = body.readLE(UInt32.self, at: at - body.startIndex)
            let len = Int(body.readLE(UInt16.self, at: at - body.startIndex + 4))
            at += 6
            guard body.endIndex - at >= len else { break }
            out.append((seq, body.subdata(in: at..<(at + len))))
            at += len
        }
        return out
    }
}

// MARK: - UDP 套接字

/// 最简单的 UDP 套接字：后台线程收，任意线程发。
final class RTSocket {
    let fd: Int32
    private var closed = false
    private let lock = NSLock()
    /// 后台线程回调：数据、来源地址
    var onPacket: ((Data, sockaddr_storage) -> Void)?

    /// Mac：在指定端口监听（同时收 IPv4 和 IPv6）
    init?(listenPort: UInt16) {
        fd = socket(AF_INET6, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return nil }
        var off: Int32 = 0, on: Int32 = 1
        setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &off, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in6()
        addr.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        addr.sin6_family = sa_family_t(AF_INET6)
        addr.sin6_port = listenPort.bigEndian
        addr.sin6_addr = in6addr_any
        let ok = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) } }
        guard ok == 0 else { Darwin.close(fd); return nil }
        Self.tune(fd)
    }

    /// iPad：连向 Mac
    init?(host: String, port: UInt16) {
        var hints = addrinfo()
        hints.ai_socktype = SOCK_DGRAM
        hints.ai_flags = AI_NUMERICSERV
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &res) == 0, let info = res else { return nil }
        defer { freeaddrinfo(res) }
        fd = socket(info.pointee.ai_family, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return nil }
        guard Darwin.connect(fd, info.pointee.ai_addr, info.pointee.ai_addrlen) == 0 else { Darwin.close(fd); return nil }
        Self.tune(fd)
    }

    private static func tune(_ fd: Int32) {
        var size: Int32 = 4 * 1024 * 1024
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &size, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &size, socklen_t(MemoryLayout<Int32>.size))
        // 交互视频的服务类型：Wi‑Fi 会优先发
        var svc: Int32 = NET_SERVICE_TYPE_VI
        setsockopt(fd, SOL_SOCKET, SO_NET_SERVICE_TYPE, &svc, socklen_t(MemoryLayout<Int32>.size))
    }

    func start() {
        let t = Thread { [weak self] in self?.readLoop() }
        t.name = "pivot.rt.read"
        t.qualityOfService = .userInteractive
        t.start()
    }

    private func readLoop() {
        var buf = [UInt8](repeating: 0, count: 2048)
        while true {
            var from = sockaddr_storage()
            var len = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let n = withUnsafeMutablePointer(to: &from) { p in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buf, buf.count, 0, $0, &len) }
            }
            if n < 0 {
                if errno == EINTR { continue }
                if isClosed { return }
                // 连接型套接字在对端不可达时会收到 ICMP 错误，忽略继续收
                if errno == ECONNREFUSED { usleep(20_000); continue }
                return
            }
            onPacket?(Data(buf[0..<n]), from)
        }
    }

    private var isClosed: Bool { lock.lock(); defer { lock.unlock() }; return closed }

    @discardableResult
    func send(_ data: Data, to addr: sockaddr_storage? = nil) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            if var a = addr {
                let len = socklen_t(a.ss_len)
                return withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, raw.baseAddress, raw.count, 0, $0, len) } } >= 0
            }
            return Darwin.send(fd, raw.baseAddress, raw.count, 0) >= 0
        }
    }

    func close() {
        lock.lock()
        guard !closed else { lock.unlock(); return }
        closed = true
        lock.unlock()
        shutdown(fd, SHUT_RDWR)
        Darwin.close(fd)
    }
}

extension sockaddr_storage {
    var debugDescription: String {
        var copy = self
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST)), serv = [CChar](repeating: 0, count: Int(NI_MAXSERV))
        _ = withUnsafePointer(to: &copy) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            getnameinfo($0, socklen_t(self.ss_len), &host, socklen_t(host.count), &serv, socklen_t(serv.count), NI_NUMERICHOST | NI_NUMERICSERV)
        } }
        return "\(String(cString: host)):\(String(cString: serv))"
    }

    func sameEndpoint(_ other: sockaddr_storage) -> Bool {
        var a = self, b = other
        let len = Int(ss_len)
        guard len == Int(other.ss_len) else { return false }
        return withUnsafeBytes(of: &a) { pa in withUnsafeBytes(of: &b) { pb in memcmp(pa.baseAddress, pb.baseAddress, len) == 0 } }
    }
}
