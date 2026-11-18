import AppKit

/// Mac 剪贴板 ⇄ iPad。Mac 这边每 0.5 秒看一次剪贴板有没有变（只比较计数，很便宜），变了就把文字或图片发过去；
/// iPad 发来的内容写进剪贴板，并记下这次变化是自己写的，不再回传。
final class ClipboardSync {
    static let maxBytes = 16 * 1024 * 1024
    private var timer: Timer?
    /// 跨会话保留：断开期间复制的内容，重连后也会发过去
    private static var lastChange = NSPasteboard.general.changeCount
    private static let lock = NSLock()
    private var lastChange: Int {
        get { Self.lock.lock(); defer { Self.lock.unlock() }; return Self.lastChange }
        set { Self.lock.lock(); Self.lastChange = newValue; Self.lock.unlock() }
    }
    var send: ((Data) -> Void)?

    func start() {
        guard timer == nil else { return }
        poll()
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChange else { return }
        lastChange = pb.changeCount
        // 密码管理器等标记为临时或隐藏的内容不同步
        let types = pb.types ?? []
        if types.contains(NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")) ||
           types.contains(NSPasteboard.PasteboardType("org.nspasteboard.TransientType")) { return }
        if let text = pb.string(forType: .string), !text.isEmpty {
            let data = Data(text.utf8)
            guard data.count <= Self.maxBytes else { return }
            send?(Data([0]) + data)
        } else if let png = Self.png(from: pb), png.count <= Self.maxBytes {
            send?(Data([1]) + png)
        }
    }

    private static func png(from pb: NSPasteboard) -> Data? {
        if let png = pb.data(forType: .png) { return png }
        guard let tiff = pb.data(forType: .tiff), let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    /// 任意线程（NSPasteboard 可以跨线程写）
    func apply(_ payload: Data) {
        guard let kind = payload.first else { return }
        let body = payload.dropFirst()
        let pb = NSPasteboard.general
        switch kind {
        case 0:
            guard let text = String(data: body, encoding: .utf8) else { return }
            pb.clearContents()
            pb.setString(text, forType: .string)
        case 1:
            pb.clearContents()
            pb.setData(Data(body), forType: .png)
        default:
            return
        }
        lastChange = pb.changeCount
    }
}
