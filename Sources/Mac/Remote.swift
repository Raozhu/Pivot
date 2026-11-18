import Foundation
import Network

/// 跨网络（两地之间）的连接。
///
/// iPad 不需要另装 VPN：它在 Pivot 里内嵌一个不建网卡的 EasyTier 节点，加入和这台 Mac 相同的组网，
/// 再经端口转发连到 Mac 的虚拟 IP。连接本身和局域网无线一样是 TLS 预共享密钥加密的，只是方向反过来：
/// iPad 主动连 Mac。组网参数取自这台 Mac 上正在运行的 EasyTier，只在插线时交给 iPad。
final class RemoteListeners {
    private var listeners: [String: NWListener] = [:]
    private let queue = DispatchQueue(label: "pivot.remote", qos: .userInteractive)
    /// 设备标识、已接入的连接（还没 start）。在内部队列上回调。
    var onConnection: ((String, NWConnection) -> Void)?
    var connectionQueue: DispatchQueue { queue }

    /// 按当前配对表重建：每台 iPad 一个端口、一把密钥
    func sync() {
        queue.async { [self] in
            let devices = PairingStore.remoteDevices()
            for (id, l) in listeners where devices[id] == nil || devices[id]?.port != l.port?.rawValue {
                l.cancel()
                listeners[id] = nil
            }
            for (id, entry) in devices where listeners[id] == nil {
                start(deviceID: id, key: entry.key, port: entry.port)
            }
        }
    }

    private func start(deviceID: String, key: Data, port: UInt16) {
        let params = Pairing.parameters(key: key)
        params.allowLocalEndpointReuse = true
        guard let p = NWEndpoint.Port(rawValue: port), let listener = try? NWListener(using: params, on: p) else {
            Log.info("远程：端口 \(port) 监听失败")
            return
        }
        listener.newConnectionHandler = { [weak self] c in self?.onConnection?(deviceID, c) }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            switch state {
            case .ready: Log.info("远程：在端口 \(port) 等待 \(PairingStore.name(for: deviceID) ?? deviceID)")
            case .failed(let e):
                Log.info("远程：端口 \(port) 出错 \(e.localizedDescription)，稍后重试")
                listener?.cancel()
                self?.queue.asyncAfter(deadline: .now() + 3) {
                    guard let self, self.listeners[deviceID] === listener else { return }
                    self.listeners[deviceID] = nil
                    self.sync()
                }
            default: break
            }
        }
        listener.start(queue: queue)
        listeners[deviceID] = listener
    }
}

/// 读这台 Mac 上正在运行的 EasyTier 的组网参数（网络名、密钥、引导节点、自己的虚拟 IP）。
enum MeshDetector {
    private static var cached: (time: Date, value: (name: String, secret: String, peers: [String], ip: String)?)?

    /// 只认手动指定了虚拟 IP 的 EasyTier（DHCP 分配的 IP 会变，iPad 记不住）
    static func detect() -> (name: String, secret: String, peers: [String], ip: String)? {
        if let cached, Date().timeIntervalSince(cached.time) < 30 { return cached.value }
        let value = parse(runningArgs() ?? launchdArgs() ?? [])
        cached = (Date(), value)
        return value
    }

    static func config(port: UInt16) -> MeshConfig? {
        guard let m = detect() else { return nil }
        return MeshConfig(networkName: m.name, networkSecret: m.secret, peers: m.peers, hostIP: m.ip, port: port)
    }

    private static func parse(_ args: [String]) -> (name: String, secret: String, peers: [String], ip: String)? {
        var name: String?, secret: String?, ip: String?
        var peers: [String] = []
        var i = 0
        func value(_ a: String, _ flag: String) -> String? {
            if a.hasPrefix(flag + "=") { return String(a.dropFirst(flag.count + 1)) }
            if a == flag, i + 1 < args.count { i += 1; return args[i] }
            return nil
        }
        while i < args.count {
            let a = args[i]
            if let v = value(a, "--network-name") { name = v }
            else if let v = value(a, "--network-secret") { secret = v }
            else if let v = value(a, "--ipv4") ?? value(a, "-i") { ip = v.split(separator: "/").first.map(String.init) }
            else if let v = value(a, "--peers") ?? value(a, "-p") { peers.append(v) }
            i += 1
        }
        guard let name, let secret, let ip, !peers.isEmpty else { return nil }
        return (name, secret, peers, ip)
    }

    /// 正在运行的 easytier-core 的命令行
    private static func runningArgs() -> [String]? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-axww", "-o", "args="]
        let pipe = Pipe()
        p.standardOutput = pipe
        guard (try? p.run()) != nil else { return nil }
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        guard let line = out.split(separator: "\n").first(where: { $0.contains("easytier-core") && $0.contains("--network-name") }) else { return nil }
        return line.split(separator: " ").map(String.init)
    }

    /// 兜底：开机自启的 launchd 配置
    private static func launchdArgs() -> [String]? {
        let dirs = ["/Library/LaunchDaemons", "/Library/LaunchAgents",
                    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents").path]
        for dir in dirs {
            for file in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] where file.lowercased().contains("easytier") {
                if let plist = NSDictionary(contentsOfFile: dir + "/" + file), let args = plist["ProgramArguments"] as? [String] { return args }
            }
        }
        return nil
    }
}
