import Foundation

/// 通过系统自带的 usbmuxd 走 USB 线连接 iPad 上的 TCP 端口。
/// 全程不经过 Wi‑Fi，也不需要 iPad 的本地网络权限。
struct MuxDevice: Equatable, Hashable {
    let id: Int
    let serial: String
    let productID: Int
}

enum MuxError: Error, CustomStringConvertible {
    case socket(Int32)
    case closed
    case malformed(String)
    case refused(Int)

    var description: String {
        switch self {
        case .socket(let e): return "socket 错误 \(e): \(String(cString: strerror(e)))"
        case .closed: return "连接已关闭"
        case .malformed(let s): return "协议错误：\(s)"
        case .refused(let n): return "usbmuxd 拒绝连接（代码 \(n)）"
        }
    }
}

enum POSIXIO {
    static func readExact(_ fd: Int32, _ count: Int) throws -> Data {
        var data = Data(count: count)
        var got = 0
        while got < count {
            let n = data.withUnsafeMutableBytes { read(fd, $0.baseAddress! + got, count - got) }
            if n > 0 { got += n } else if n == 0 { throw MuxError.closed } else if errno != EINTR { throw MuxError.socket(errno) }
        }
        return data
    }

    static func writeAll(_ fd: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { raw in
            var sent = 0
            while sent < raw.count {
                let n = write(fd, raw.baseAddress! + sent, raw.count - sent)
                if n > 0 { sent += n } else if n < 0 && errno != EINTR { throw MuxError.socket(errno) }
            }
        }
    }
}

enum USBMux {
    private static let path = "/var/run/usbmuxd"

    static func open() throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw MuxError.socket(errno) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        withUnsafeMutablePointer(to: &addr.sun_path) { p in
            p.withMemoryRebound(to: CChar.self, capacity: capacity) { _ = strlcpy($0, path, capacity) }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let r = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, len) } }
        guard r == 0 else { let e = errno; close(fd); throw MuxError.socket(e) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        return fd
    }

    static func send(_ fd: Int32, _ dict: [String: Any], tag: UInt32 = 1) throws {
        let body = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
        var packet = Data(capacity: 16 + body.count)
        packet.appendLE(UInt32(16 + body.count))
        packet.appendLE(UInt32(1))   // 协议版本：plist
        packet.appendLE(UInt32(8))   // 消息类型：plist
        packet.appendLE(tag)
        packet.append(body)
        try POSIXIO.writeAll(fd, packet)
    }

    static func receive(_ fd: Int32) throws -> [String: Any] {
        let header = try POSIXIO.readExact(fd, 16)
        let length = Int(header.readLE(UInt32.self, at: 0))
        guard length >= 16, length < 1 << 20 else { throw MuxError.malformed("长度 \(length)") }
        let body = try POSIXIO.readExact(fd, length - 16)
        guard let dict = try PropertyListSerialization.propertyList(from: body, options: [], format: nil) as? [String: Any] else {
            throw MuxError.malformed("不是字典")
        }
        return dict
    }

    private static var clientInfo: [String: Any] {
        ["ClientVersionString": "pivot-1", "ProgName": "Pivot", "kLibUSBMuxVersion": 3]
    }

    /// 连接到设备上的 TCP 端口；成功后返回的 fd 就是到该端口的字节流。
    static func connect(deviceID: Int, port: UInt16) throws -> Int32 {
        let fd = try open()
        do {
            var msg = clientInfo
            msg["MessageType"] = "Connect"
            msg["DeviceID"] = deviceID
            msg["PortNumber"] = Int(port.bigEndian)   // usbmuxd 要求网络字节序
            try send(fd, msg)
            let reply = try receive(fd)
            let code = reply["Number"] as? Int ?? -1
            guard code == 0 else { throw MuxError.refused(code) }
            return fd
        } catch {
            close(fd)
            throw error
        }
    }

    static func listenMessage() -> [String: Any] {
        var msg = clientInfo
        msg["MessageType"] = "Listen"
        return msg
    }
}

/// 监听 USB 设备插拔。回调在内部线程上触发。
final class MuxWatcher {
    var onAttach: ((MuxDevice) -> Void)?
    var onDetach: ((Int) -> Void)?
    private var running = false
    private var fd: Int32 = -1
    private let lock = NSLock()

    func start() {
        lock.lock(); defer { lock.unlock() }
        guard !running else { return }
        running = true
        let t = Thread { [weak self] in self?.loop() }
        t.name = "pivot.usbmux.watch"
        t.start()
    }

    func stop() {
        lock.lock(); running = false; let f = fd; lock.unlock()
        if f >= 0 { shutdown(f, SHUT_RDWR) }
    }

    private var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }

    private func loop() {
        while isRunning {
            var known = Set<Int>()
            do {
                let f = try USBMux.open()
                lock.lock(); fd = f; lock.unlock()
                defer { close(f); lock.lock(); fd = -1; lock.unlock() }
                try USBMux.send(f, USBMux.listenMessage())
                while isRunning {
                    let msg = try USBMux.receive(f)
                    switch msg["MessageType"] as? String {
                    case "Attached":
                        guard let id = msg["DeviceID"] as? Int, let props = msg["Properties"] as? [String: Any] else { continue }
                        // 只走有线
                        guard (props["ConnectionType"] as? String) == "USB" else { continue }
                        known.insert(id)
                        onAttach?(MuxDevice(id: id, serial: props["SerialNumber"] as? String ?? "", productID: props["ProductID"] as? Int ?? 0))
                    case "Detached":
                        if let id = msg["DeviceID"] as? Int, known.remove(id) != nil { onDetach?(id) }
                    default:
                        break
                    }
                }
            } catch {
                for id in known { onDetach?(id) }
                if isRunning { Thread.sleep(forTimeInterval: 2) }
            }
        }
    }
}
