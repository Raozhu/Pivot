import UIKit

/// iPad 剪贴板 ⇄ Mac。
/// iPad → Mac 不轮询：读别的应用复制的内容会弹系统的「允许粘贴」提示，所以只在你往 Mac 里粘贴（⌘V）时才读。
/// 平时只记剪贴板的变化计数（读计数不会弹提示），粘贴时发现有新复制的内容，先发给 Mac 再按下 ⌘V。
final class PadClipboard {
    static let maxBytes = 16 * 1024 * 1024
    /// 上次已经同步过（或是 Mac 写进来）的剪贴板计数。存下来，重启应用后也不会把旧内容再发一遍
    private var lastChange: Int {
        get { UserDefaults.standard.object(forKey: "clipboardChange") as? Int ?? UIPasteboard.general.changeCount }
        set { UserDefaults.standard.set(newValue, forKey: "clipboardChange") }
    }
    var send: ((Data) -> Void)?

    init() {
        // 首次安装：之前就在剪贴板里的内容不算新复制的
        if UserDefaults.standard.object(forKey: "clipboardChange") == nil { lastChange = UIPasteboard.general.changeCount }
    }

    /// 剪贴板里有没有还没同步给 Mac 的新内容（不读内容，不弹提示）
    var hasNewContent: Bool { UIPasteboard.general.changeCount != lastChange }

    /// 有新内容就读出来发给 Mac。返回是否发了
    @discardableResult
    func syncIfChanged() -> Bool {
        let pb = UIPasteboard.general
        let count = pb.changeCount
        guard count != lastChange else { return false }
        lastChange = count
        if pb.hasStrings, let text = pb.string, !text.isEmpty {
            let data = Data(text.utf8)
            guard data.count <= Self.maxBytes else { return false }
            send?(Data([0]) + data)
            return true
        } else if pb.hasImages, let png = pb.image?.pngData(), png.count <= Self.maxBytes {
            send?(Data([1]) + png)
            return true
        }
        return false
    }

    /// Mac 复制的内容写进 iPad 剪贴板（写不会弹提示）。主线程
    func apply(_ payload: Data) {
        guard let kind = payload.first else { return }
        let body = Data(payload.dropFirst())
        let pb = UIPasteboard.general
        switch kind {
        case 0:
            guard let text = String(data: body, encoding: .utf8) else { return }
            pb.string = text
        case 1:
            guard let image = UIImage(data: body) else { return }
            pb.image = image
        default:
            return
        }
        lastChange = pb.changeCount
    }
}
