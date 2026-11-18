import Foundation
import Network

/// 与 iPad 之间的双向消息通道。有线（USB 文件描述符）和无线（加密网络连接）各有一个实现。
protocol Channel: AnyObject {
    /// 在通道内部线程上回调
    var onMessage: ((MsgType, Data) -> Void)? { get set }
    var onClose: (() -> Void)? { get set }
    /// 每发完一帧视频后回调
    var onVideoSent: (() -> Void)? { get set }
    /// 尚未交给系统发送的视频帧数，用来在对端跟不上时跳帧而不是堆积延迟
    var videoBacklog: Int { get }
    func start()
    func send(_ type: MsgType, _ payload: Data)
    func sendVideo(header: VideoHeader, data: Data)
    func close()
}

extension Channel {
    func send(_ type: MsgType) { send(type, Data()) }
}

private func videoPacket(_ header: VideoHeader, _ data: Data) -> Data {
    var packet = frameHeader(type: .video, payloadLength: VideoHeader.size + data.count)
    packet.append(header.encode())
    packet.append(data)
    return packet
}

/// 有线：usbmuxd 给的文件描述符。读在专用线程，写在串行队列。
final class FDChannel: Channel {
    private let fd: Int32
    private let writeQueue = DispatchQueue(label: "pivot.channel.write", qos: .userInteractive)
    private let lock = NSLock()
    private var closed = false
    private var pendingVideoFrames = 0

    var onMessage: ((MsgType, Data) -> Void)?
    var onClose: (() -> Void)?
    var onVideoSent: (() -> Void)?

    init(fd: Int32) {
        self.fd = fd
        var size: Int32 = 512 * 1024
        setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &size, socklen_t(MemoryLayout<Int32>.size))
    }

    func start() {
        let t = Thread { [weak self] in self?.readLoop() }
        t.name = "pivot.channel.read"
        t.qualityOfService = .userInteractive
        t.start()
    }

    var videoBacklog: Int { lock.lock(); defer { lock.unlock() }; return pendingVideoFrames }

    func send(_ type: MsgType, _ payload: Data) {
        enqueue(frameHeader(type: type, payloadLength: payload.count) + payload, isVideo: false)
    }

    func sendVideo(header: VideoHeader, data: Data) {
        enqueue(videoPacket(header, data), isVideo: true)
    }

    private func enqueue(_ packet: Data, isVideo: Bool) {
        lock.lock()
        if closed { lock.unlock(); return }
        if isVideo { pendingVideoFrames += 1 }
        lock.unlock()
        writeQueue.async { [self] in
            defer { if isVideo { lock.lock(); pendingVideoFrames -= 1; lock.unlock(); onVideoSent?() } }
            guard !isClosed else { return }
            do { try POSIXIO.writeAll(fd, packet) } catch { close() }
        }
    }

    private var isClosed: Bool { lock.lock(); defer { lock.unlock() }; return closed }

    func close() {
        lock.lock()
        if closed { lock.unlock(); return }
        closed = true
        lock.unlock()
        shutdown(fd, SHUT_RDWR)
    }

    private func readLoop() {
        defer {
            close()
            Darwin.close(fd)
            onClose?()
        }
        while true {
            do {
                let header = try POSIXIO.readExact(fd, 5)
                let length = Int(header.readLE(UInt32.self, at: 0))
                guard length >= 1, length <= Wire.maxFrame else { return }
                let payload = length > 1 ? try POSIXIO.readExact(fd, length - 1) : Data()
                if let type = MsgType(rawValue: header[header.startIndex + 4]) { onMessage?(type, payload) }
            } catch {
                return
            }
        }
    }
}

/// 无线：已经握手完成的加密网络连接。
final class NWChannel: Channel {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var closed = false
    private var pendingVideoFrames = 0

    var onMessage: ((MsgType, Data) -> Void)?
    var onClose: (() -> Void)?
    var onVideoSent: (() -> Void)?

    /// - Parameter queue: 该连接启动时使用的队列
    init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.finish()
            default: break
            }
        }
        queue.async { [self] in readHeader() }
    }

    var videoBacklog: Int { lock.lock(); defer { lock.unlock() }; return pendingVideoFrames }

    func send(_ type: MsgType, _ payload: Data) {
        guard !isClosed else { return }
        connection.send(content: frameHeader(type: type, payloadLength: payload.count) + payload, completion: .contentProcessed { _ in })
    }

    func sendVideo(header: VideoHeader, data: Data) {
        lock.lock()
        if closed { lock.unlock(); return }
        pendingVideoFrames += 1
        lock.unlock()
        connection.send(content: videoPacket(header, data), completion: .contentProcessed { [weak self] _ in
            guard let self else { return }
            self.lock.lock(); self.pendingVideoFrames -= 1; self.lock.unlock()
            self.onVideoSent?()
        })
    }

    private var isClosed: Bool { lock.lock(); defer { lock.unlock() }; return closed }

    func close() { connection.cancel() }

    private func finish() {
        lock.lock()
        if closed { lock.unlock(); return }
        closed = true
        lock.unlock()
        onClose?()
    }

    private func readHeader() {
        connection.receive(minimumIncompleteLength: 5, maximumLength: 5) { [weak self] data, _, _, error in
            guard let self else { return }
            guard let data, data.count == 5, error == nil else { self.connection.cancel(); self.finish(); return }
            let length = Int(data.readLE(UInt32.self, at: 0))
            let rawType = data[data.startIndex + 4]
            guard length >= 1, length <= Wire.maxFrame else { self.connection.cancel(); return }
            if length == 1 {
                if let type = MsgType(rawValue: rawType) { self.onMessage?(type, Data()) }
                self.readHeader()
            } else {
                self.connection.receive(minimumIncompleteLength: length - 1, maximumLength: length - 1) { [weak self] body, _, _, error in
                    guard let self else { return }
                    guard let body, body.count == length - 1, error == nil else { self.connection.cancel(); self.finish(); return }
                    if let type = MsgType(rawValue: rawType) { self.onMessage?(type, body) }
                    self.readHeader()
                }
            }
        }
    }
}
