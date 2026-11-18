import Foundation
import CoreGraphics
import ColorSync

/// 一块系统认可的虚拟显示器，分辨率与 iPad 屏幕逐像素对应。
///
/// 横、竖各有一套模式表（混在一张表里时系统会把一部分模式标成不可切换）。
/// 系统对「运行中换表」和「显式切模式」的处理有不少不公开的规则，实测并不总是生效，
/// 所以切换布局时逐级尝试，每一级都以「当前模式是否已是目标」为准：
/// 1. 换表，等系统自己落到目标模式（最快，约 0.2 秒，窗口不动）
/// 2. 目标模式在表里但没落上去 → 显式切换
/// 3. 新表迟迟没装上 → 重建显示器（身份不变，系统会把窗口放回来；显示器编号会变）
final class VirtualDisplay {
    /// 缩放档位：点数相对「逐像素 2x」的倍数。1.0 最锐利，越大可用空间越多。
    static let scaleSteps: [Double] = [0.8, 1.0, 1.2, 1.4, 1.6]

    struct Layout: Equatable {
        /// iPad 画面像素尺寸（当前方向）
        var pixelWidth: Int
        var pixelHeight: Int
        var scale: Double

        var isPortrait: Bool { pixelHeight >= pixelWidth }
        /// 该档位下的逻辑点数
        var points: (w: Int, h: Int) { VirtualDisplay.points(pixelWidth: pixelWidth, pixelHeight: pixelHeight, scale: scale) }
    }

    private var display: CGVirtualDisplay?
    /// 旧显示器已释放、新显示器还没建出来
    private var rebuilding = false
    private let name: String
    private let longSide: Int
    private let shortSide: Int
    private let refreshRate: Double
    private let identity: String
    private var installedPortrait: Bool
    /// 重建后会变
    private(set) var displayID: CGDirectDisplayID

    // 进行中的布局请求
    private var pending: Layout?
    private var pendingSince: UInt64 = 0
    private var swapped = false
    private var recreated = false

    /// 每个 CGVirtualDisplay 实例一个令牌：只认当前实例的「被系统收回」通知，重建时旧实例的通知忽略
    private final class Token { var handler: (() -> Void)? }
    private var token = Token()
    /// 系统主动收回这块显示器时触发
    var onTerminated: (() -> Void)? {
        didSet { token.handler = onTerminated }
    }

    /// 最近一次切换尚未完成的原因
    private(set) var lastError: String?
    /// 最近一次切换成功时走的是哪一级
    private(set) var lastPath = ""

    static func points(pixelWidth: Int, pixelHeight: Int, scale: Double) -> (w: Int, h: Int) {
        func even(_ v: Double) -> Int { max(2, Int((v / 2).rounded()) * 2) }
        return (even(Double(pixelWidth) / 2 * scale), even(Double(pixelHeight) / 2 * scale))
    }

    /// - Parameters:
    ///   - nativeWidth/nativeHeight: iPad 竖放时的物理像素
    ///   - identity: 用来生成稳定的显示器序列号，让系统记住每台 iPad 的排列位置
    ///   - portrait/scale: 初始方向与缩放档位
    init?(name: String, nativeWidth: Int, nativeHeight: Int, refreshRate: Double, identity: String, portrait: Bool, scale: Double) {
        self.name = name
        shortSide = min(nativeWidth, nativeHeight)
        longSide = max(nativeWidth, nativeHeight)
        self.refreshRate = refreshRate
        self.identity = identity
        guard let made = Self.make(name: name, shortSide: shortSide, longSide: longSide, refreshRate: refreshRate,
                                   identity: identity, portrait: portrait, preferred: scale, token: token) else { return nil }
        display = made
        displayID = made.displayID
        installedPortrait = portrait
    }

    private static func make(name: String, shortSide: Int, longSide: Int, refreshRate: Double, identity: String,
                             portrait: Bool, preferred: Double, token: Token) -> CGVirtualDisplay? {
        let maxScale = scaleSteps.max() ?? 1
        let maxBacking = UInt32((Double(longSide) * maxScale).rounded(.up)) + 16
        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.queue = DispatchQueue.main
        descriptor.name = name
        descriptor.maxPixelsWide = maxBacking
        descriptor.maxPixelsHigh = maxBacking
        // 约 264ppi（iPad 级别的像素密度）
        descriptor.sizeInMillimeters = CGSize(width: Double(shortSide) / 264 * 25.4, height: Double(longSide) / 264 * 25.4)
        descriptor.vendorID = 0x5056
        descriptor.productID = 0x0001
        descriptor.serialNum = stableSerial(identity)
        descriptor.terminationHandler = { _, _ in token.handler?() }
        guard let display = CGVirtualDisplay(descriptor: descriptor),
              display.apply(settings(shortSide: shortSide, longSide: longSide, portrait: portrait, preferred: preferred, refreshRate: refreshRate)),
              display.displayID != 0 else { return nil }
        return display
    }

    /// - Parameter preferred: 想要的缩放档位，排在表首。换表后系统多半直接落到表首的模式上。
    private static func settings(shortSide: Int, longSide: Int, portrait: Bool, preferred: Double, refreshRate: Double) -> CGVirtualDisplaySettings {
        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = 1
        let (pw, ph) = portrait ? (shortSide, longSide) : (longSide, shortSide)
        var seen = Set<String>()
        var modes: [CGVirtualDisplayMode] = []
        for scale in [preferred] + scaleSteps.sorted(by: >) {
            let p = points(pixelWidth: pw, pixelHeight: ph, scale: scale)
            if seen.insert("\(p.w)x\(p.h)").inserted {
                modes.append(CGVirtualDisplayMode(width: UInt(p.w), height: UInt(p.h), refreshRate: refreshRate))
            }
        }
        settings.modes = modes
        return settings
    }

    private static func stableSerial(_ s: String) -> UInt32 {
        var h: UInt32 = 2166136261
        for b in s.utf8 { h = (h ^ UInt32(b)) &* 16777619 }
        return h == 0 ? 1 : h
    }

    /// 这块显示器能否直接给同一台 iPad 的新会话接着用（换线、断线重连时窗口就不必搬家）
    func matches(nativeWidth: Int, nativeHeight: Int, refreshRate: Double, identity: String) -> Bool {
        min(nativeWidth, nativeHeight) == shortSide && max(nativeWidth, nativeHeight) == longSide
            && refreshRate == self.refreshRate && identity == self.identity
    }

    /// 公开的 CGDisplayCreateUUIDFromDisplayID 对虚拟显示器返回 nil（WiredPad 实测），改用 CoreGraphics 私有的 CGSCopyDisplayUUID。
    /// 显示器刚建好时可能还拿不到，所以重试一会儿。
    var uuidString: String? { Self.uuid(of: displayID) }

    static func uuid(of displayID: CGDirectDisplayID) -> String? {
        typealias Copy = @convention(c) (UInt32, UnsafeMutablePointer<Unmanaged<CFUUID>?>) -> Int32
        guard let cg = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY),
              let sym = dlsym(cg, "CGSCopyDisplayUUID") else { return nil }
        let copy = unsafeBitCast(sym, to: Copy.self)
        for _ in 0..<30 {
            var out: Unmanaged<CFUUID>?
            if copy(displayID, &out) == 0, let u = out?.takeRetainedValue() { return CFUUIDCreateString(nil, u) as String }
            usleep(100_000)
        }
        return nil
    }

    var bounds: CGRect { CGDisplayBounds(displayID) }

    private func allModes() -> [CGDisplayMode] {
        let options = [kCGDisplayShowDuplicateLowResolutionModes as String: true] as CFDictionary
        return (CGDisplayCopyAllDisplayModes(displayID, options) as? [CGDisplayMode]) ?? []
    }

    private func isCurrent(_ p: (w: Int, h: Int)) -> Bool {
        guard let m = CGDisplayCopyDisplayMode(displayID) else { return false }
        return m.width == p.w && m.height == p.h && m.pixelWidth == p.w * 2
    }

    /// 把显示器切到指定布局。需要反复调用直到返回 true（调用间隔约 20 毫秒）；
    /// 内部按「换表 → 显式切换 → 重建」逐级推进。调用后 `displayID` 可能已经变了。
    @discardableResult
    func apply(_ layout: Layout) -> Bool {
        let p = layout.points
        let now = monotonicNs()
        if pending != layout {
            pending = layout
            pendingSince = now
            swapped = false
            recreated = false
            if installedPortrait != layout.isPortrait {
                // 第一级：换表
                _ = display?.apply(Self.settings(shortSide: shortSide, longSide: longSide, portrait: layout.isPortrait,
                                                 preferred: layout.scale, refreshRate: refreshRate))
                installedPortrait = layout.isPortrait
                swapped = true
            }
        }
        if rebuilding {
            // 第三级进行中：旧的已经释放。等系统把它彻底撤掉，再用同一身份建新的
            guard Double(now - pendingSince) / 1e6 > 500 else { lastError = "正在重建显示器"; return false }
            let fresh = Token()
            fresh.handler = onTerminated
            guard let made = Self.make(name: name, shortSide: shortSide, longSide: longSide, refreshRate: refreshRate,
                                       identity: identity, portrait: layout.isPortrait, preferred: layout.scale, token: fresh) else {
                lastError = "正在重建显示器"
                return false
            }
            token = fresh
            display = made
            displayID = made.displayID
            installedPortrait = layout.isPortrait
            rebuilding = false
            recreated = true
            pendingSince = now
            lastError = "已重建，等待上线"
            return false
        }
        if isCurrent(p) {
            if recreated { lastPath = "重建" } else if swapped { lastPath = "换表落位" } else { lastPath = "已在目标模式" }
            lastError = nil
            return true
        }
        let elapsedMs = Double(now - pendingSince) / 1e6
        let target = allModes().first { $0.width == p.w && $0.height == p.h && $0.pixelWidth == p.w * 2 && $0.isUsableForDesktopGUI() }

        if let target {
            // 刚换过表：先给系统一点时间自己落位
            if swapped, !recreated, elapsedMs < 300 {
                lastError = "等待系统落位"
                return false
            }
            // 第二级：显式切换
            let result = CGDisplaySetDisplayMode(displayID, target, nil)
            if result == .success, isCurrent(p) {
                lastPath = recreated ? "重建" : "显式切换"
                lastError = nil
                return true
            }
            lastError = "显式切换未生效（\(result.rawValue)）"
            return false
        }

        // 目标模式还不在表里
        if !recreated, elapsedMs > (swapped ? 600 : 250) {
            // 第三级：重建显示器。先释放旧的（同一身份不能同时存在两块），下次调用再建新的
            token.handler = nil
            autoreleasepool { display = nil }
            rebuilding = true
            pendingSince = now
            lastError = "正在重建显示器"
            return false
        }
        lastError = "目标模式尚未出现"
        return false
    }

    /// 当前模式的点数与像素数
    var currentMode: (points: (Int, Int), pixels: (Int, Int))? {
        guard let m = CGDisplayCopyDisplayMode(displayID) else { return nil }
        return ((m.width, m.height), (m.pixelWidth, m.pixelHeight))
    }

    /// 当前模式是否真的是 2x 渲染
    var isHiDPI: Bool {
        guard let m = CGDisplayCopyDisplayMode(displayID) else { return false }
        return m.pixelWidth == m.width * 2
    }
}
