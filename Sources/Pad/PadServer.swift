import Foundation
import Network

/// iPad 端的监听器，两条路：
/// - 有线：Mac 通过 USB（usbmuxd）连进来，连接来自本机回环地址，不加密也不经过网络。
/// - 无线：Bonjour 广播 + TLS 预共享密钥，只有插线配对过的 Mac 能连上。
final class PadServer {
    enum Event {
        /// 参数：是否有线
        case connected(Bool)
        case config(StreamConfig)
        case format(Data)
        case video(VideoHeader, Data)
        case feedback(Feedback)
        /// Mac 上的焦点进入（true）或离开输入框
        case textFocus(Bool)
        /// 参数：对端是否声明「彻底结束」（不必保留画面等重连）
        case disconnected(Bool)
        /// UDP 实时通道收到的一帧（可能带参数集）
        case rtVideo(RTFrameAssembler.Frame)
        /// UDP 实时通道有帧补不回来，需要关键帧
        case rtLoss(Int)
        /// UDP 实时通道通了
        case rtReady
        /// 一个声音包（u32 序号 + Opus）
        case audio(Data)
        /// Mac 剪贴板变了
        case clipboard(Data)
    }

    /// UDP 实时通道（Mac 发来参数后才建）
    private var rt: RTClient?
    /// 当前连接是不是经组网主动连出去的（远程）
    private var dialedRemote = false

    private func closeRealtime() {
        rt?.close()
        rt = nil
    }

    private func startRealtime(_ offer: RT.Offer) {
        closeRealtime()
        guard let key = pairingKey, let salt = Data(base64Encoded: offer.salt), let connection else { return }
        let host: String, port: UInt16
        if dialedRemote {
            // 远程：内嵌 EasyTier 把本机这个 UDP 端口转发到 Mac
            host = "127.0.0.1"; port = Wire.meshLocalPort
        } else if case .hostPort(let h, _) = connection.endpoint {
            switch h {
            case .ipv4(let a): host = "\(a)"
            case .ipv6(let a): host = "\(a)"
            case .name(let n, _): host = n
            @unknown default: return
            }
            port = offer.port
        } else {
            return
        }
        guard let client = RTClient(host: host, port: port, pairingKey: key, salt: salt) else {
            print("实时通道：连不上 \(host):\(port)")
            return
        }
        // 都转到网络队列上：和 TCP 来的画面同一个队列，解码器不会被两个线程同时用
        client.onFrame = { [weak self, weak client] f in
            self?.queue.async { guard let self, let client, self.rt === client else { return }; self.onEvent?(.rtVideo(f)) }
        }
        client.onLoss = { [weak self, weak client] n in
            self?.queue.async { guard let self, let client, self.rt === client else { return }; self.onEvent?(.rtLoss(n)) }
        }
        client.onAudio = { [weak self] p in self?.onEvent?(.audio(p)) }
        client.onReady = { [weak self, weak client] in
            self?.queue.async {
                guard let self, let client, self.rt === client else { return }
                print("实时通道：UDP 已通（\(host):\(port)）")
                self.onEvent?(.rtReady)
            }
        }
        client.start()
        rt = client
    }

    private let queue = DispatchQueue(label: "pivot.pad.net", qos: .userInteractive)
    private var listener: NWListener?
    private var wirelessListener: NWListener?
    private var connection: NWConnection?
    private var running = false
    private var peerSaidFinal = false

    /// 启动前设置：无线配对密钥、设备标识、广播用的名字
    var pairingKey: Data?
    var deviceID = ""
    var serviceName = "iPad"

    /// 在网络队列上回调
    var onEvent: ((Event) -> Void)?

    func start() {
        queue.async { [self] in
            guard !running else { return }
            running = true
            startListener()
            startWirelessListener()
        }
    }

    func stop() {
        queue.async { [self] in
            running = false
            if let connection {
                connection.send(content: frameHeader(type: .bye, payloadLength: 0), completion: .contentProcessed { _ in connection.cancel() })
            }
            connection = nil
            closeRealtime()
            listener?.cancel()
            listener = nil
            wirelessListener?.cancel()
            wirelessListener = nil
        }
    }

    private func startWirelessListener() {
        guard let key = pairingKey, let listener = try? NWListener(using: Pairing.parameters(key: key)) else {
            retryWirelessListener()
            return
        }
        var txt = NWTXTRecord()
        txt[Wire.txtDeviceID] = deviceID
        listener.service = NWListener.Service(name: serviceName, type: Wire.bonjourType, txtRecord: txt)
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection, wired: false) }
        listener.stateUpdateHandler = { [weak self] state in
            print("无线监听状态：\(state)")
            if case .failed = state { self?.wirelessListener?.cancel(); self?.wirelessListener = nil; self?.retryWirelessListener() }
        }
        listener.start(queue: queue)
        wirelessListener = listener
    }

    private func retryWirelessListener() {
        queue.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.running, self.wirelessListener == nil else { return }
            self.startWirelessListener()
        }
    }

    private func startListener() {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let params = NWParameters(tls: nil, tcp: tcp)
        params.allowLocalEndpointReuse = true
        params.requiredInterfaceType = .loopback
        guard let port = NWEndpoint.Port(rawValue: Wire.port), let listener = try? NWListener(using: params, on: port) else {
            retryListener()
            return
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection, wired: true) }
        listener.stateUpdateHandler = { [weak self] state in
            print("监听状态：\(state)")
            if case .failed = state { self?.listener?.cancel(); self?.listener = nil; self?.retryListener() }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    private func retryListener() {
        queue.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, self.running, self.listener == nil else { return }
            self.startListener()
        }
    }

    private func accept(_ incoming: NWConnection, wired: Bool) {
        // 同一时间只服务一台 Mac；新连接直接顶替旧连接（比如从无线换到有线），画面不中断
        connection?.cancel()
        pendingDial?.cancel()
        pendingDial = nil
        closeRealtime()
        connection = incoming
        dialedRemote = false
        peerSaidFinal = false
        print("新连接（\(wired ? "有线" : "无线")）来自 \(incoming.endpoint)")
        incoming.stateUpdateHandler = { [weak self, weak incoming] state in
            guard let self, let incoming, self.connection === incoming else { return }
            switch state {
            case .ready:
                self.onEvent?(.connected(wired))
                self.readHeader(incoming)
            case .failed, .cancelled:
                self.connection = nil
                self.closeRealtime()
                self.onEvent?(.disconnected(self.peerSaidFinal))
            default:
                break
            }
        }
        incoming.start(queue: queue)
    }

    private var pendingDial: NWConnection?

    /// 远程：主动连 Mac（经内嵌 EasyTier 的本机转发端口）。已有连接或正在连时什么都不做。
    func dial(_ endpoint: NWEndpoint) {
        queue.async { [self] in
            guard running, connection == nil, pendingDial == nil, let key = pairingKey else { return }
            let c = NWConnection(to: endpoint, using: Pairing.parameters(key: key))
            pendingDial = c
            c.stateUpdateHandler = { [weak self, weak c] state in
                guard let self, let c, self.pendingDial === c else { return }
                switch state {
                case .ready:
                    self.pendingDial = nil
                    guard self.connection == nil, self.running else { c.cancel(); return }
                    print("远程：已连上 Mac")
                    self.closeRealtime()
                    self.connection = c
                    self.dialedRemote = true
                    self.peerSaidFinal = false
                    c.stateUpdateHandler = { [weak self, weak c] state in
                        guard let self, let c, self.connection === c else { return }
                        if case .failed = state { self.connection = nil; self.closeRealtime(); self.onEvent?(.disconnected(self.peerSaidFinal)) }
                        if case .cancelled = state { self.connection = nil; self.closeRealtime(); self.onEvent?(.disconnected(self.peerSaidFinal)) }
                    }
                    self.onEvent?(.connected(false))
                    self.readHeader(c)
                case .failed, .waiting:
                    self.pendingDial = nil
                    c.cancel()
                default:
                    break
                }
            }
            c.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 8) { [weak self, weak c] in
                guard let self, let c, self.pendingDial === c else { return }
                self.pendingDial = nil
                c.cancel()
            }
        }
    }

    private func readHeader(_ c: NWConnection) {
        c.receive(minimumIncompleteLength: 5, maximumLength: 5) { [weak self] data, _, _, error in
            guard let self, let data, data.count == 5, error == nil else { c.cancel(); return }
            let length = Int(data.readLE(UInt32.self, at: 0))
            let type = data[data.startIndex + 4]
            guard length >= 1, length <= Wire.maxFrame else { c.cancel(); return }
            if length == 1 {
                self.dispatch(type, Data())
                self.readHeader(c)
            } else {
                c.receive(minimumIncompleteLength: length - 1, maximumLength: length - 1) { [weak self] body, _, _, error in
                    guard let self, let body, body.count == length - 1, error == nil else { c.cancel(); return }
                    self.dispatch(type, body)
                    self.readHeader(c)
                }
            }
        }
    }

    private func dispatch(_ rawType: UInt8, _ payload: Data) {
        guard let type = MsgType(rawValue: rawType) else { return }
        switch type {
        case .video:
            guard let header = VideoHeader.decode(payload) else { return }
            onEvent?(.video(header, payload.subdata(in: (payload.startIndex + VideoHeader.size)..<payload.endIndex)))
        case .format:
            onEvent?(.format(payload))
        case .config:
            if let config = jsonDecode(StreamConfig.self, payload) { onEvent?(.config(config)) }
        case .textFocus:
            onEvent?(.textFocus(payload.first == 1))
        case .feedback:
            if let fb = jsonDecode(Feedback.self, payload) { onEvent?(.feedback(fb)) }
        case .audio:
            onEvent?(.audio(payload))
        case .clipboard:
            onEvent?(.clipboard(payload))
        case .rtOffer:
            if let offer = jsonDecode(RT.Offer.self, payload) { startRealtime(offer) }
        case .ping:
            send(.pong, payload)
        case .bye:
            peerSaidFinal = payload.first == 1
            connection?.cancel()
        default:
            break
        }
    }

    /// 任意线程可调用
    func send(_ type: MsgType, _ payload: Data = Data()) {
        queue.async { [self] in
            // 触控和回执优先走 UDP：不会被前面卡住的包挡住
            if let rt, (type == .touch || type == .ack), rt.ready {
                if type == .touch {
                    let critical = TouchPacket.decode(payload)?.contacts.contains { $0.phase != .moved && $0.phase != .stationary } ?? false
                    rt.sendTouch(payload, critical: critical)
                } else {
                    rt.sendAck(payload)
                }
                return
            }
            guard let connection, connection.state == .ready else { return }
            connection.send(content: frameHeader(type: type, payloadLength: payload.count) + payload, completion: .contentProcessed { _ in })
        }
    }
}
