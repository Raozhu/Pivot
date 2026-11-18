import Foundation
import Network
import UIKit

/// 远程（两地之间）连接：iPad 不用另装 VPN。
///
/// Pivot 在自己进程里跑一个不建网卡的 EasyTier 节点（不需要 NetworkExtension 权限），加入和 Mac 相同的组网，
/// 把本机 `Wire.meshLocalPort` 转发到 Mac 的虚拟 IP。没连上 Mac 时每隔几秒经这个端口用配对密钥主动连一次。
/// 组网参数由 Mac 在插线时给出（见 `MeshConfig`），之后存在本机。App 退到后台时节点一起停掉。
final class MeshLink {
    private static let storeKey = "meshConfig"
    private static let instanceName = "pivot"

    static var config: MeshConfig? {
        get { UserDefaults.standard.data(forKey: storeKey).flatMap { jsonDecode(MeshConfig.self, $0) } }
        set { UserDefaults.standard.set(newValue.map { jsonEncode($0) }, forKey: storeKey) }
    }

    private let queue = DispatchQueue(label: "pivot.mesh")
    private let pathMonitor = NWPathMonitor()
    /// STUN 服务器：国内几台常用的，直接写 IP 免得域名被代理解析成假地址；域名也留着作后备
    private static let stunServers = [
        "111.206.174.3:3478", "180.76.162.88:3478", "175.6.157.109:3478", "43.136.118.213:3478",
        "stun.miwifi.com:3478", "stun.chat.bilibili.com:3478",
    ]

    init() {
        // 告诉 EasyTier 当前真正上网的网卡（蜂窝 / Wi‑Fi），STUN 和打洞绑在它上面，绕开 VPN 和代理（见 scripts/easytier-bind-if.patch）
        pathMonitor.pathUpdateHandler = { path in
            let physical = path.availableInterfaces.first { [.cellular, .wifi, .wiredEthernet].contains($0.type) }
            let name = physical?.name ?? ""
            if (getenv("ET_BIND_IF").map { String(cString: $0) } ?? "") != name {
                setenv("ET_BIND_IF", name, 1)
                print("远程：打洞走网卡 \(name.isEmpty ? "（默认）" : name)")
            }
        }
        pathMonitor.start(queue: queue)
    }
    private var running: MeshConfig?
    private var timer: DispatchSourceTimer?
    private var wantDial = false
    private var idleSince = Date()
    private var active = false
    /// 状态说明（主线程回调）
    var onStatus: ((String) -> Void)?
    /// 需要发起一次远程连接：本机端点和连接参数交给 PadServer
    var dial: ((NWEndpoint) -> Void)?

    /// App 回到前台
    func start() {
        queue.async { [self] in
            active = true
            if let config = Self.config { startNode(config) } else { report("远程未开启：先用数据线连一次 Mac") }
            if timer == nil {
                let t = DispatchSource.makeTimerSource(queue: queue)
                t.schedule(deadline: .now() + 1, repeating: 2.5)
                t.setEventHandler { [weak self] in self?.tick() }
                t.resume()
                timer = t
            }
        }
    }

    /// App 退到后台
    func stop() {
        queue.async { [self] in
            active = false
            timer?.cancel()
            timer = nil
            stopNode()
        }
    }

    /// 有线连接时 Mac 给了（可能更新了的）组网参数
    func update(_ config: MeshConfig) {
        queue.async { [self] in
            guard config != Self.config else { return }
            Self.config = config
            print("远程：收到组网参数（\(config.networkName)，Mac \(config.hostIP):\(config.port)）")
            if running != nil { stopNode() }
            if active { startNode(config) }
        }
    }

    /// 是否已连上 Mac（任何方式）。没连上且空闲了几秒才走远程，给有线和局域网留出先连上的时间。
    func setConnected(_ connected: Bool) {
        queue.async { [self] in
            wantDial = !connected
            idleSince = Date()
        }
    }

    private func tick() {
        guard running != nil, wantDial, Date().timeIntervalSince(idleSince) > 3,
              let port = NWEndpoint.Port(rawValue: Wire.meshLocalPort) else { return }
        dial?(.hostPort(host: "127.0.0.1", port: port))
    }

    private func startNode(_ config: MeshConfig) {
        guard running == nil else { return }
        let toml = Self.toml(config)
        let r = toml.withCString { run_network_instance($0) }
        if r == 0 {
            running = config
            report("远程已就绪")
            print("远程：EasyTier 已启动，经 127.0.0.1:\(Wire.meshLocalPort) 转发到 \(config.hostIP):\(config.port)")
        } else {
            let msg = Self.lastError()
            report("远程启动失败：\(msg)")
            print("远程：EasyTier 启动失败 \(msg)")
        }
    }

    private func stopNode() {
        guard running != nil else { return }
        _ = retain_network_instance(nil, 0)
        running = nil
        print("远程：EasyTier 已停止")
    }

    private func report(_ s: String) { DispatchQueue.main.async { self.onStatus?(s) } }

    private static func lastError() -> String {
        var p: UnsafePointer<CChar>?
        get_error_msg(&p)
        guard let p else { return "未知错误" }
        defer { free_string(p) }
        return String(cString: p)
    }

    private static func quote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private static func toml(_ c: MeshConfig) -> String {
        let name = UIDevice.current.name.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? String($0) : "-" }.joined()
        var t = """
        instance_name = \(quote(instanceName))
        hostname = \(quote("pivot-" + name))
        dhcp = true
        listeners = []
        stun_servers = [\(stunServers.map(quote).joined(separator: ", "))]

        [network_identity]
        network_name = \(quote(c.networkName))
        network_secret = \(quote(c.networkSecret))

        [flags]
        no_tun = true
        latency_first = true

        [console_logger]
        level = "warn"

        [[port_forward]]
        bind_addr = \(quote("127.0.0.1:\(Wire.meshLocalPort)"))
        dst_addr = \(quote("\(c.hostIP):\(c.port)"))
        proto = "tcp"

        [[port_forward]]
        bind_addr = \(quote("127.0.0.1:\(Wire.meshLocalPort)"))
        dst_addr = \(quote("\(c.hostIP):\(c.port)"))
        proto = "udp"

        """
        for peer in c.peers { t += "\n[[peer]]\nuri = \(quote(peer))\n" }
        return t
    }
}
