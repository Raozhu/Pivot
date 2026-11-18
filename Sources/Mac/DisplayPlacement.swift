import Foundation
import CoreGraphics

/// 记住 iPad 虚拟显示器在「显示器排列」里的位置（在主屏哪一边、靠上还是靠下），重连或旋转后放回原处。
/// 系统不会替虚拟显示器记排列，每次新建都会摆回默认位置。
/// 记的是相对主屏的边和沿边的位置比例，而不是绝对坐标：横竖屏切换后尺寸变了也能贴着同一边放好。
enum DisplayPlacement {
    struct Saved: Codable, Equatable {
        /// 0 左 1 右 2 上 3 下；4 不贴主屏（比如挨着另一块外接屏），直接记坐标
        var side: Int
        /// 沿边的位置：iPad 中心点相对主屏这条边的比例
        var offset: Double
        var x: Int = 0
        var y: Int = 0
    }

    private static func key(_ deviceID: String) -> String { "displayPlacement.\(deviceID)" }

    static func load(deviceID: String) -> Saved? {
        guard let data = UserDefaults.standard.data(forKey: key(deviceID)) else { return nil }
        return try? JSONDecoder().decode(Saved.self, from: data)
    }

    static func save(_ saved: Saved, deviceID: String) {
        guard load(deviceID: deviceID) != saved, let data = try? JSONEncoder().encode(saved) else { return }
        UserDefaults.standard.set(data, forKey: key(deviceID))
        Log.info("记住显示器位置：\(["左", "右", "上", "下", "自定义"][saved.side])边 \(String(format: "%.2f", saved.offset))")
    }

    /// 读当前位置。镜像中（只用 iPad 模式）或它自己就是主屏时不记
    static func capture(_ id: CGDirectDisplayID) -> Saved? {
        let main = CGMainDisplayID()
        guard id != main, CGDisplayIsInMirrorSet(id) == 0, CGDisplayIsOnline(id) != 0 else { return nil }
        let m = CGDisplayBounds(main), b = CGDisplayBounds(id)
        guard b.width > 0, m.width > 0 else { return nil }
        let raw = Saved(side: 4, offset: 0, x: Int(b.minX), y: Int(b.minY))
        if abs(b.maxX - m.minX) <= 1 { return Saved(side: 0, offset: Double((b.midY - m.minY) / m.height)) }
        if abs(b.minX - m.maxX) <= 1 { return Saved(side: 1, offset: Double((b.midY - m.minY) / m.height)) }
        if abs(b.maxY - m.minY) <= 1 { return Saved(side: 2, offset: Double((b.midX - m.minX) / m.width)) }
        if abs(b.minY - m.maxY) <= 1 { return Saved(side: 3, offset: Double((b.midX - m.minX) / m.width)) }
        return raw
    }

    /// 放回记下的位置
    static func restore(_ id: CGDirectDisplayID, _ saved: Saved) {
        let main = CGMainDisplayID()
        guard id != main, CGDisplayIsInMirrorSet(id) == 0 else { return }
        let m = CGDisplayBounds(main), b = CGDisplayBounds(id)
        guard b.width > 0 else { return }
        var x: CGFloat, y: CGFloat
        // 沿边的位置限制在主屏范围内，保证两块屏至少有一段挨着
        func along(_ origin: CGFloat, _ length: CGFloat, _ size: CGFloat) -> CGFloat {
            let v = origin + CGFloat(saved.offset) * length - size / 2
            return min(origin + length - 1, max(origin - size + 1, v))
        }
        switch saved.side {
        case 0: x = m.minX - b.width; y = along(m.minY, m.height, b.height)
        case 1: x = m.maxX; y = along(m.minY, m.height, b.height)
        case 2: y = m.minY - b.height; x = along(m.minX, m.width, b.width)
        case 3: y = m.maxY; x = along(m.minX, m.width, b.width)
        default: x = CGFloat(saved.x); y = CGFloat(saved.y)
        }
        let tx = Int32(x.rounded()), ty = Int32(y.rounded())
        guard abs(Int32(b.minX) - tx) > 1 || abs(Int32(b.minY) - ty) > 1 else { return }
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else { return }
        CGConfigureDisplayOrigin(config, id, tx, ty)
        let r = CGCompleteDisplayConfiguration(config, .forSession)
        Log.info("显示器放回原位（\(tx), \(ty)）\(r == .success ? "" : "失败 \(r.rawValue)")")
    }
}
