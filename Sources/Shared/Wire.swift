import Foundation

/// Mac 与 iPad 之间的有线协议。
/// 帧格式：u32 长度（含类型字节，小端）+ u8 类型 + 负载。
enum Wire {
    static let port: UInt16 = 47101
    static let version = 1
    static let maxFrame = 64 * 1024 * 1024
    /// 无线发现用的 Bonjour 服务类型
    static let bonjourType = "_pivot._tcp"
    /// Bonjour TXT 记录里存放设备标识的键
    static let txtDeviceID = "id"
    /// 远程：Mac 给每台配对过的 iPad 各开一个加密监听端口，从这里起依次往后排（TLS 预共享密钥一个监听只能认一把）
    static let remotePortBase: UInt16 = 47103
    /// 远程：iPad 内嵌的 EasyTier 把本机这个端口转发到 Mac 的虚拟 IP
    static let meshLocalPort: UInt16 = 47110
}

/// 远程连接要用的组网参数。只在有线握手后由 Mac 交给 iPad，绝不经无线发送。
/// iPad 用它在 App 里跑一个不建网卡的 EasyTier 节点，再经端口转发连到 Mac。
struct MeshConfig: Codable, Equatable {
    var networkName: String
    var networkSecret: String
    /// EasyTier 的中继/引导节点，如 tcp://1.2.3.4:11010
    var peers: [String]
    /// Mac 在组网里的虚拟 IP
    var hostIP: String
    /// Mac 给这台 iPad 开的加密监听端口
    var port: UInt16
}

enum MsgType: UInt8 {
    case hello = 1           // pad → mac，JSON(Hello)
    case config = 2          // mac → pad，JSON(StreamConfig)
    case format = 3          // mac → pad，HEVC 参数集
    case video = 4           // mac → pad，一帧
    case touch = 5           // pad → mac，TouchPacket
    case viewport = 6        // pad → mac，JSON(Viewport)：方向或尺寸变化
    case keyframeRequest = 7 // pad → mac
    case ping = 8            // 任一方，u64 发送方时间
    case pong = 9            // 回显 ping 的负载
    case ack = 10            // pad → mac，u32 帧序号 + u32 解码入队耗时(微秒)
    case feedback = 11       // mac → pad，JSON(Feedback)：触控视觉反馈
    case bye = 12            // 任一方，主动结束；负载 1 字节为 1 表示「彻底结束，不必等重连」
    case key = 13            // pad → mac，外接键盘：u16 HID 用途码 + u8 是否按下
    case scroll = 14         // pad → mac，外接触控板/鼠标滚动：f32 dx + f32 dy + u8 阶段(0 开始 1 变化 2 结束)
    case text = 15           // pad → mac，屏幕键盘输入的文字（UTF‑8）
    case mode = 16           // pad → mac，u8：DisplayMode
    case textFocus = 17      // mac → pad，u8：Mac 上当前焦点是不是输入框（1 是）
    case rtOffer = 18        // mac → pad，JSON(RT.Offer)：打开 UDP 实时通道
    case audio = 19          // mac → pad，u32 序号 + 一个 Opus 包（10 ms，48 kHz 立体声）
    case audioEnable = 20    // pad → mac，u8：1 传声音，0 停（Mac 连采集都停掉）
    case clipboard = 21      // 双向，u8 类型（0 文字 UTF‑8，1 PNG 图片）+ 内容
    case quality = 22        // pad → mac，u8：StreamQuality
    case pause = 23          // pad → mac，u8：1 iPad 退到后台（停发画面和声音，会话保留），0 回到前台
    case padStats = 24       // pad → mac，JSON(PadStats)：每秒一次 iPad 端的实况，写进 Mac 日志
    case rtDirect = 25       // 双向，JSON(DirectPath.Candidates)：自己直连套接字的公网地址，对方据此打洞
}

/// iPad 端每秒的实况（所有时间单位毫秒）。Mac 看不到 iPad 的日志，靠这个判断卡在哪一段
struct PadStats: Codable {
    var frames: Int          // 收到的画面帧数
    var frameGapMax: Double  // 相邻两帧到达的最大间隔
    var frameHitches: Int    // 到达间隔超过 40 ms 的次数（画面在动时）
    var presented: Int       // 真正送上屏的帧数
    var presentGapMax: Double
    var decodeMax: Double    // 解码入队最长耗时
    var touches: Int         // 发出的触控包
    var touchLagMax: Double  // 手指事件发生 → 发出去的最长耗时（主线程忙就会变大）
    var mainHitchMax: Double // 主线程一帧的最长耗时（正常约 16.7）
    var net: String          // wifi / cellular / wired / other
    var thermal: Int         // 0 正常 … 3 严重
    var lowPower: Bool
}

struct Hello: Codable {
    var version: Int
    var name: String
    var model: String
    var deviceID: String
    /// 屏幕竖放时的物理像素尺寸
    var nativeWidth: Int
    var nativeHeight: Int
    var scale: Double
    var maxFPS: Int
    var viewport: Viewport
    /// 无线配对密钥（Base64）。只在有线连接的握手里携带，Mac 存下后才能无线连接这台 iPad。
    var pairingKey: String?
    /// iPad 端支持的能力（旧版没有这个字段）。见 `PadCaps`
    var caps: [String]?
    /// 清晰度偏好（StreamQuality 原始值；旧版没有，按自动处理）
    var quality: UInt8?
}

/// 无线时的清晰度偏好。决定带宽紧张时先降分辨率还是先降帧率
enum StreamQuality: UInt8, CaseIterable {
    /// 按网络自动：远程偏流畅，局域网偏清晰
    case auto = 0
    /// 流畅优先：分辨率降得更早、更多，帧率尽量满
    case smooth = 1
    /// 清晰优先：分辨率尽量高，带宽很紧时宁可降到 30 帧
    case clear = 2
    /// 原画：始终按 iPad 屏幕原分辨率编码，只靠码率和帧率适应网络
    case original = 3

    var label: String {
        switch self {
        case .auto: return "自动"
        case .smooth: return "流畅优先"
        case .clear: return "清晰优先"
        case .original: return "原画"
        }
    }
}

/// iPad 在握手里声明的能力。Mac 只对声明过的能力启用对应功能，旧版 iPad 照常工作。
enum PadCaps {
    /// 能显示比画面区域小的编码画面（拉伸铺满），Mac 才会在带宽紧张时降编码分辨率
    static let scaledFrames = "scaled"
    /// 支持 UDP 实时通道（画面和触控走 UDP）
    static let realtime = "rt1"
    /// 能在 iPad 上做超分辨率
    static let superResolution = "sr"
}

/// iPad 当前界面方向下，画面区域的像素尺寸
/// iPad 怎么当屏幕用
enum DisplayMode: Int, Codable, CaseIterable {
    /// 独立的扩展屏
    case extend = 0
    /// 镜像 Mac 主屏
    case mirror = 1
    /// 只用 iPad：Mac 自己的屏幕改为镜像 iPad，菜单栏、程序坞和所有窗口都到 iPad 上
    case solo = 2

    var label: String {
        switch self {
        case .extend: return "扩展屏"
        case .mirror: return "镜像"
        case .solo: return "仅 iPad"
        }
    }
}

struct Viewport: Codable, Equatable {
    var width: Int
    var height: Int
    var isPortrait: Bool { height >= width }
}

struct StreamConfig: Codable {
    var width: Int
    var height: Int
    var fps: Int
    var codec: String
    var hostName: String
    /// 当前是否镜像 Mac 主屏
    var mirror: Bool?
    /// 当前显示模式（DisplayMode 的原始值）
    var mode: Int?
    /// 远程组网参数，只在有线连接里携带
    var mesh: MeshConfig?
    /// 连接方式："wired" / "local" / "remote"
    var transport: String?
}

struct Feedback: Codable {
    enum Kind: String, Codable { case longPress, rightClick, dragStart }
    var kind: Kind
    var x: Double
    var y: Double
}

// MARK: - 触控

enum TouchPhase: UInt8 { case began = 0, moved = 1, stationary = 2, ended = 3, cancelled = 4 }
enum TouchKind: UInt8 { case finger = 0, pencil = 1, hover = 2, pointer = 3 }

struct TouchContact {
    var id: UInt8
    var phase: TouchPhase
    var kind: TouchKind
    /// 归一化坐标，原点在画面左上角
    var x: Float
    var y: Float
    var pressure: Float
    var altitude: Float
    var azimuth: Float
    var radius: Float
}

struct TouchPacket {
    var timestamp: UInt64
    var contacts: [TouchContact]

    static let contactSize = 3 + 6 * 4

    func encode() -> Data {
        var d = Data(capacity: 9 + contacts.count * Self.contactSize)
        d.appendLE(timestamp)
        d.append(UInt8(contacts.count))
        for c in contacts {
            d.append(c.id); d.append(c.phase.rawValue); d.append(c.kind.rawValue)
            d.appendLE(c.x.bitPattern); d.appendLE(c.y.bitPattern)
            d.appendLE(c.pressure.bitPattern); d.appendLE(c.altitude.bitPattern)
            d.appendLE(c.azimuth.bitPattern); d.appendLE(c.radius.bitPattern)
        }
        return d
    }

    static func decode(_ d: Data) -> TouchPacket? {
        var r = ByteReader(d)
        guard let ts: UInt64 = r.read(), let n: UInt8 = r.read() else { return nil }
        var cs: [TouchContact] = []
        cs.reserveCapacity(Int(n))
        for _ in 0..<n {
            guard let id: UInt8 = r.read(), let ph: UInt8 = r.read(), let k: UInt8 = r.read(),
                  let x: UInt32 = r.read(), let y: UInt32 = r.read(), let p: UInt32 = r.read(),
                  let al: UInt32 = r.read(), let az: UInt32 = r.read(), let rad: UInt32 = r.read(),
                  let phase = TouchPhase(rawValue: ph), let kind = TouchKind(rawValue: k) else { return nil }
            cs.append(TouchContact(id: id, phase: phase, kind: kind,
                                   x: Float(bitPattern: x), y: Float(bitPattern: y),
                                   pressure: Float(bitPattern: p), altitude: Float(bitPattern: al),
                                   azimuth: Float(bitPattern: az), radius: Float(bitPattern: rad)))
        }
        return TouchPacket(timestamp: ts, contacts: cs)
    }
}

// MARK: - 视频

struct VideoHeader {
    static let size = 1 + 4 + 8
    var isKey: Bool
    var index: UInt32
    var captureNs: UInt64
    /// 长期参考帧刷新：参考的是 iPad 确认收到过的帧，丢帧后不用等关键帧，解码器状态还在就能直接接上
    var isRefresh = false

    func encode() -> Data {
        var d = Data(capacity: Self.size)
        d.append((isKey ? 1 : 0) | (isRefresh ? 2 : 0)); d.appendLE(index); d.appendLE(captureNs)
        return d
    }

    static func decode(_ d: Data) -> VideoHeader? {
        var r = ByteReader(d)
        guard let f: UInt8 = r.read(), let i: UInt32 = r.read(), let t: UInt64 = r.read() else { return nil }
        return VideoHeader(isKey: f & 1 == 1, index: i, captureNs: t, isRefresh: f & 2 != 0)
    }
}

enum FormatPayload {
    static func encode(nalLengthSize: Int, parameterSets: [Data]) -> Data {
        var d = Data()
        d.append(UInt8(nalLengthSize)); d.append(UInt8(parameterSets.count))
        for p in parameterSets { d.appendLE(UInt16(p.count)); d.append(p) }
        return d
    }

    static func decode(_ d: Data) -> (nalLengthSize: Int, parameterSets: [Data])? {
        var r = ByteReader(d)
        guard let n: UInt8 = r.read(), let count: UInt8 = r.read() else { return nil }
        var sets: [Data] = []
        for _ in 0..<count {
            guard let len: UInt16 = r.read(), let bytes = r.readBytes(Int(len)) else { return nil }
            sets.append(bytes)
        }
        return (Int(n), sets)
    }
}

// MARK: - 字节工具

extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ v: T) {
        var le = v.littleEndian
        Swift.withUnsafeBytes(of: &le) { append(contentsOf: $0) }
    }

    func readLE<T: FixedWidthInteger>(_ type: T.Type, at offset: Int) -> T {
        var v: T = 0
        let size = MemoryLayout<T>.size
        let start = startIndex + offset
        Swift.withUnsafeMutableBytes(of: &v) { dst in
            _ = self.copyBytes(to: dst, from: start..<(start + size))
        }
        return T(littleEndian: v)
    }
}

struct ByteReader {
    private let data: Data
    private var offset = 0
    init(_ data: Data) { self.data = data }

    var remaining: Int { data.count - offset }

    mutating func read<T: FixedWidthInteger>() -> T? {
        let size = MemoryLayout<T>.size
        guard remaining >= size else { return nil }
        let v = data.readLE(T.self, at: offset)
        offset += size
        return v
    }

    mutating func readBytes(_ n: Int) -> Data? {
        guard remaining >= n else { return nil }
        let s = data.startIndex + offset
        offset += n
        return data.subdata(in: s..<(s + n))
    }

    mutating func rest() -> Data {
        let s = data.startIndex + offset
        offset = data.count
        return data.subdata(in: s..<data.endIndex)
    }
}

func frameHeader(type: MsgType, payloadLength: Int) -> Data {
    var d = Data(capacity: 5)
    d.appendLE(UInt32(payloadLength + 1))
    d.append(type.rawValue)
    return d
}

func jsonEncode<T: Encodable>(_ v: T) -> Data { (try? JSONEncoder().encode(v)) ?? Data() }
func jsonDecode<T: Decodable>(_ type: T.Type, _ d: Data) -> T? { try? JSONDecoder().decode(type, from: d) }

/// 单调时钟（纳秒）。两端各自的时钟不同步，只用于同端差值。
func monotonicNs() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }
