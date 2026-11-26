import Foundation
import Darwin

/// 远程直连：两端各开一个绑在真实网卡上的 UDP 套接字（绕开代理和 EasyTier），用 STUN 问出自己的公网地址，
/// 经 TLS 控制连接交换后互相发探测包打洞。打通以后画面、触控、回执都走这条路，不再经过 iPad 上 EasyTier 的用户态协议栈
/// （它缓冲小、优先级低，大块 UDP 一突发就丢）。直连断了自动退回组网。
enum DirectPath {
    /// 国内可用的 STUN 服务器（和 iPad 上 EasyTier 用的同一批）
    /// 只用纯 IP：开着代理时域名会被解析成假 IP（198.18.x），绑在物理网卡上根本发不到
    static let stunServers = [
        "111.206.174.3:3478", "180.76.162.88:3478", "175.6.157.109:3478", "43.136.118.213:3478",
    ]

    /// 探测包的序号段：最高位置 1，和正常包分开计数、分开防重放，不会被当成丢包
    static let probeSeqBit: UInt64 = 1 << 63
    static func isProbeSeq(_ s: UInt64) -> Bool { s & probeSeqBit != 0 }

    /// 网卡的 IPv4 地址
    static func ipv4(of interface: String) -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return nil }
        defer { freeifaddrs(list) }
        var p = list
        while let cur = p {
            defer { p = cur.pointee.ifa_next }
            guard String(cString: cur.pointee.ifa_name) == interface, let sa = cur.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            var a = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
            var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            inet_ntop(AF_INET, &a, &buf, socklen_t(buf.count))
            return String(cString: buf)
        }
        return nil
    }

    /// 控制连接上交换的候选地址
    struct Candidates: Codable {
        var addrs: [String]   // "ip:port"
    }

    /// 当前真正上网的物理网卡（en*，有 IPv4 地址），Mac 用。有代理 TUN 时默认路由指向 utun，直连必须绕开
    static func physicalInterface() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        var names: [String] = []
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = p {
            defer { p = cur.pointee.ifa_next }
            guard let sa = cur.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET),
                  (cur.pointee.ifa_flags & UInt32(IFF_UP)) != 0, (cur.pointee.ifa_flags & UInt32(IFF_LOOPBACK)) == 0 else { continue }
            let name = String(cString: cur.pointee.ifa_name)
            let v4 = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            // 跳过 169.254 和 EasyTier 的 10.144.144.x
            if v4 >> 16 == 0xA9FE || v4 >> 8 == 0x0A9090 { continue }
            if name.hasPrefix("en") || name.hasPrefix("pdp_ip") { names.append(name) }
        }
        // 有线优先于无线（en0 在笔记本上是 Wi‑Fi，台式机上是网口，都可以）
        return names.sorted().first
    }

    /// 解析 "host:port" 为 IPv4 地址
    static func resolve(_ hostPort: String) -> sockaddr_storage? {
        guard let colon = hostPort.lastIndex(of: ":") else { return nil }
        let host = String(hostPort[..<colon]), port = String(hostPort[hostPort.index(after: colon)...])
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_DGRAM
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, port, &hints, &res) == 0, let info = res else { return nil }
        defer { freeaddrinfo(res) }
        var out = sockaddr_storage()
        memcpy(&out, info.pointee.ai_addr, Int(info.pointee.ai_addrlen))
        return out
    }
}

/// 最小 STUN（RFC 5389）：只发绑定请求、只解析 IPv4 的 XOR-MAPPED-ADDRESS / MAPPED-ADDRESS
enum STUN {
    private static let cookie: UInt32 = 0x2112A442

    static func request() -> Data {
        var d = Data([0x00, 0x01, 0x00, 0x00])
        withUnsafeBytes(of: cookie.bigEndian) { d.append(contentsOf: $0) }
        for _ in 0..<12 { d.append(UInt8.random(in: 0...255)) }
        return d
    }

    /// 是不是 STUN 绑定成功响应（加密的实时通道包不可能恰好以它开头）
    static func isResponse(_ d: Data) -> Bool {
        guard d.count >= 20 else { return false }
        let b = [UInt8](d.prefix(8))
        return b[0] == 0x01 && b[1] == 0x01 && b[4] == 0x21 && b[5] == 0x12 && b[6] == 0xA4 && b[7] == 0x42
    }

    /// 解析出 "ip:port"
    static func mappedAddress(_ d: Data) -> String? {
        let b = [UInt8](d)
        guard isResponse(d) else { return nil }
        var i = 20
        var plain: String?
        while i + 4 <= b.count {
            let type = Int(b[i]) << 8 | Int(b[i + 1]), len = Int(b[i + 2]) << 8 | Int(b[i + 3])
            let v = i + 4
            guard v + len <= b.count else { break }
            if (type == 0x0020 || type == 0x0001), len >= 8, b[v + 1] == 0x01 {
                var port = UInt16(b[v + 2]) << 8 | UInt16(b[v + 3])
                var ip = [b[v + 4], b[v + 5], b[v + 6], b[v + 7]]
                if type == 0x0020 {
                    port ^= 0x2112
                    ip = [ip[0] ^ 0x21, ip[1] ^ 0x12, ip[2] ^ 0xA4, ip[3] ^ 0x42]
                    return "\(ip[0]).\(ip[1]).\(ip[2]).\(ip[3]):\(port)"
                }
                plain = "\(ip[0]).\(ip[1]).\(ip[2]).\(ip[3]):\(port)"
            }
            i = v + ((len + 3) & ~3)
        }
        return plain
    }
}

/// 一条直连的状态（两端共用）：问公网地址、打洞、判断通没通
final class DirectLink {
    let socket: RTSocket
    private let lock = NSLock()
    private(set) var publicAddr: String?
    private var peerCandidates: [sockaddr_storage] = []
    private var punchUntil: UInt64 = 0
    /// 打通后对方的地址，以及最近一次从直连收到对方的包
    private(set) var peer: sockaddr_storage?
    private var lastRx: UInt64 = 0
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "pivot.direct", qos: .userInteractive)

    /// 问到公网地址（内部队列）
    var onPublicAddr: ((String) -> Void)?
    /// 打洞期间要发的探测包（已加密），由通道提供
    var makeProbe: (() -> Data?)?

    private let interface: String?
    init?(interface: String?) {
        guard let s = RTSocket(boundTo: interface) else { return nil }
        socket = s
        self.interface = interface
    }

    /// 本机局域网候选（网卡地址 + 直连端口）：两端在同一个出口后面时，绕回公网地址往往不通，走局域网地址
    var localCandidate: String? {
        guard let port = socket.localPort else { return nil }
        let iface = (interface?.isEmpty == false ? interface : nil) ?? DirectPath.physicalInterface()
        guard let iface, let ip = DirectPath.ipv4(of: iface) else { return nil }
        return "\(ip):\(port)"
    }

    /// 要报给对方的全部候选
    var candidates: [String] { [publicAddr, localCandidate].compactMap { $0 } }

    func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(100))
        var n = 0
        t.setEventHandler { [weak self] in
            guard let self else { return }
            n += 1
            // 公网地址：一开始每 0.5 秒问一次直到问到，之后每 20 秒问一次（NAT 映射可能变）
            let needStun = self.lockedPublic == nil ? n % 5 == 1 : n % 200 == 0
            if needStun {
                for s in DirectPath.stunServers.prefix(3) { if let a = DirectPath.resolve(s) { self.socket.send(STUN.request(), to: a) } }
            }
            self.punch()
        }
        t.resume()
        timer = t
    }

    private var lockedPublic: String? { lock.lock(); defer { lock.unlock() }; return publicAddr }
    private var probeSeq: UInt64 = 0
    /// 探测包用的下一个序号（探测段）
    func nextProbeSeq() -> UInt64 { lock.lock(); defer { lock.unlock() }; probeSeq += 1; return DirectPath.probeSeqBit | probeSeq }

    /// 处理直连套接字收到的包。STUN 响应在这里消化掉，返回 true
    func handleSTUN(_ data: Data) -> Bool {
        guard STUN.isResponse(data) else { return false }
        guard let addr = STUN.mappedAddress(data) else { return true }
        lock.lock()
        let changed = publicAddr != addr
        publicAddr = addr
        lock.unlock()
        if changed { onPublicAddr?(addr) }
        return true
    }

    /// 对方报来的候选地址：接下来 6 秒里每 100 毫秒往每个地址发一个探测包
    func addPeerCandidates(_ addrs: [String]) {
        let resolved = addrs.compactMap { DirectPath.resolve($0) }
        lock.lock()
        peerCandidates = resolved
        punchUntil = monotonicNs() + 6_000_000_000
        lock.unlock()
    }

    private func punch() {
        lock.lock()
        let targets = monotonicNs() < punchUntil && !aliveLocked ? peerCandidates : []
        lock.unlock()
        guard !targets.isEmpty, let probe = makeProbe?() else { return }
        for t in targets { socket.send(probe, to: t) }
    }

    /// 从直连收到对方合法的包
    func heard(from: sockaddr_storage) {
        lock.lock()
        peer = from
        lastRx = monotonicNs()
        lock.unlock()
    }

    private var aliveLocked: Bool { peer != nil && monotonicNs() - lastRx < 1_500_000_000 }
    /// 直连最近 1.5 秒内收到过对方的包
    var alive: Bool { lock.lock(); defer { lock.unlock() }; return aliveLocked }
    var peerAddr: sockaddr_storage? { lock.lock(); defer { lock.unlock() }; return aliveLocked ? peer : nil }

    func close() {
        timer?.cancel()
        timer = nil
        socket.close()
    }
}
