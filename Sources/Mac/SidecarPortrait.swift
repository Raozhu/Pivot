import AppKit
import ScreenCaptureKit
import CoreMedia
import CoreVideo
import QuartzCore

/// 「随航竖屏」模式：借用系统随航的连接，把画面变成竖屏，手指直接在 iPad 上操作。
///
/// 1. 用户照常用随航把 iPad 接成横屏副屏（iPad 上开旋转锁定）。
/// 2. 建一块竖屏虚拟显示器，录下它的画面，转 90° 后全屏铺在随航屏上。
/// 3. 竖屏贴着主屏排列，随航屏挪开，只留一小段接缝并在那里挡住光标；落到随航屏上的窗口自动搬走。
///
/// 4. 触控：macOS 27 的随航触控不经过任何事件监听点，只交给手指下那个窗口上的手势识别器（Apple TN3212）。
///    手指下正是铺画面的这层窗口，所以在它上面挂 `SidecarTouchRecognizer` 拿原始触点，
///    转 90° 后交给触控后端：Pivot 的触摸屏驱动启用时，作为原生触点送进绑定到竖屏的虚拟触摸屏
///    （`HIDTouchscreenInjector`，手感和随航一样）；否则由 `SyntheticInjector` 合成点击、滚动、缩放。
///    Info.plist 里的 `NSIsTouchNative` 让系统不再把这些触控另外模拟成鼠标。
///
/// 试过且走不通（2026-11-17，macOS 27）：用 SkyLight 的 `SLSSetDisplayRotation(随航屏, 90/270)` 强制旋转随航屏。
/// 窗口服务器接受，随航屏变成竖屏尺寸；但随航换算触点时不管旋转，90° 和 270° 下触点都对不上，
/// iPad 那边的随航界面跟着转成竖屏时还会把横的画幅缩在中间。MonitorPanel 的 setOrientation 直接拒绝（随航屏 canChangeOrientation 为 0）。
final class SidecarPortrait: NSObject, SCStreamOutput, SCStreamDelegate {
    static let shared = SidecarPortrait()
    static let sidecarVendor: UInt32 = 0x6161706c

    /// true：画面顺时针转 90°（iPad 逆时针竖起来拿）；false 反过来
    static var clockwise: Bool {
        get { UserDefaults.standard.object(forKey: "sidecarClockwise") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "sidecarClockwise") }
    }

    private(set) var active = false
    private(set) var status = ""
    var onChange: (() -> Void)?

    private var sidecarID: CGDirectDisplayID = 0
    private var sidecarBounds = CGRect.zero
    private var display: VirtualDisplay?
    private var window: NSWindow?
    private let imageLayer = CALayer()
    private var stream: SCStream?
    /// 硬件层监听：挡住从接缝挤进随航屏的光标
    private var taps: [(port: CFMachPort, source: CFRunLoopSource)] = []
    private let captureQueue = DispatchQueue(label: "pivot.sidecar.capture", qos: .userInteractive)
    private var remapped = 0
    /// 开启前随航屏的位置，关掉时还原
    private var originalSidecarOrigin: CGPoint?
    private var rescueTimer: Timer?
    /// 上一次鼠标事件的落点（不在随航屏上的）
    private var lastCursor = CGPoint(x: -100_000, y: -100_000)
    /// 把随航触点变成竖屏上的点击、滚动、缩放
    private var injector: TouchInjector?
    private var touchCount = 0
    /// 最近一次收到随航原生触点的时间；这段时间内随航屏上冒出来的鼠标事件视为系统的模拟，丢掉
    private var lastTouchTime = 0.0

    /// 当前接着的随航显示器
    static func findSidecar() -> CGDirectDisplayID? {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var n: UInt32 = 0
        CGGetActiveDisplayList(16, &ids, &n)
        return ids.prefix(Int(n)).first { CGDisplayVendorNumber($0) == sidecarVendor }
    }

    // MARK: - 开关

    func start() {
        guard !active else { return }
        guard let sid = Self.findSidecar() else { setStatus("没找到随航显示器：先在控制中心里把 iPad 连成随航"); return }
        guard let mode = CGDisplayCopyDisplayMode(sid) else { setStatus("读不到随航显示器的分辨率"); return }
        sidecarID = sid
        sidecarBounds = CGDisplayBounds(sid)
        // 竖屏虚拟显示器：随航屏的像素宽高对调，点数也正好对调，换算时 1:1
        let pw = mode.pixelWidth, ph = mode.pixelHeight
        guard let made = VirtualDisplay(name: "Pivot 竖屏", nativeWidth: min(pw, ph), nativeHeight: max(pw, ph),
                                        refreshRate: 60, identity: "sidecar-portrait", portrait: true, scale: 1.0) else {
            setStatus("无法创建竖屏虚拟显示器"); return
        }
        display = made
        active = true
        Log.info("随航竖屏：随航 \(sid) \(Int(sidecarBounds.width))x\(Int(sidecarBounds.height)) 像素 \(pw)x\(ph)，虚拟屏 \(made.displayID)")
        makeWindow()
        settle(VirtualDisplay.Layout(pixelWidth: min(pw, ph), pixelHeight: max(pw, ph), scale: 1.0), tries: 40)
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(driverActivated),
                                               name: TouchDriverExtension.activated, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(appWillTerminate),
                                               name: NSApplication.willTerminateNotification, object: nil)
        setStatus("已开启")
    }

    func stop() {
        guard active else { return }
        active = false
        NotificationCenter.default.removeObserver(self, name: NSApplication.didChangeScreenParametersNotification, object: nil)
        for t in taps {
            CGEvent.tapEnable(tap: t.port, enable: false)
            CFRunLoopRemoveSource(CFRunLoopGetMain(), t.source, .commonModes)
        }
        taps = []
        rescueTimer?.invalidate()
        rescueTimer = nil
        injector?.reset()
        injector = nil
        if let stream { self.stream = nil; Task { try? await stream.stopCapture() } }
        window?.orderOut(nil)
        window = nil
        display = nil
        restoreArrangement()
        Log.info("随航竖屏：已关闭，收到随航触点 \(touchCount) 次，换算鼠标事件 \(remapped) 个")
        setStatus("")
    }

    /// 把虚拟屏落到 2x 竖屏模式（可能要换表或重建，所以反复尝试），落位后再开始录屏和换算
    private func settle(_ layout: VirtualDisplay.Layout, tries: Int) {
        guard active, let display else { return }
        if display.apply(layout) || tries <= 0 {
            let b = display.bounds
            Log.info("随航竖屏：虚拟屏 \(display.displayID) 落位 \(Int(b.width))x\(Int(b.height))（\(display.lastPath)\(display.lastError.map { "，" + $0 } ?? "")）")
            arrange()
            installTap()
            injector = InjectorFactory.make(displayID: display.displayID, displayUUID: display.uuidString, feedback: { _ in })
            Log.info("随航竖屏：触控后端 \(injector?.label ?? "-")")
            Task { await self.startCapture(pixelWidth: layout.pixelWidth, pixelHeight: layout.pixelHeight) }
            let timer = Timer(timeInterval: 0.8, repeats: true) { [weak self] _ in self?.rescueWindows() }
            RunLoop.main.add(timer, forMode: .common)
            rescueTimer = timer
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.settle(layout, tries: tries - 1) }
    }

    // MARK: - 显示器排列

    /// 竖屏虚拟屏放到随航原来的位置（贴着其他屏幕），随航屏挪到它的外侧下方，只留 20 点的一小段边相接。
    /// 不能只角对角：那样随航坐标在排列上「够不着」，投递的事件会被系统卡在角上。
    /// 只对本次登录生效，关掉时还原。
    private func arrange() {
        guard let display else { return }
        let s = CGDisplayBounds(sidecarID)
        let v = display.bounds
        let main = CGDisplayBounds(CGMainDisplayID())
        if originalSidecarOrigin == nil { originalSidecarOrigin = s.origin }
        // 以主屏为基准：随航原本在主屏左边就放左边，否则放右边；竖直方向和主屏居中对齐。
        // 不依赖随航当前的位置（上次异常退出可能没还原）。
        let onLeft = s.midX < main.midX
        let x = onLeft ? main.minX - v.width : main.maxX
        let y = (main.midY - v.height / 2).rounded()
        let sx = onLeft ? x - s.width : x + v.width
        let sy = y + v.height - 20
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else { return }
        CGConfigureDisplayOrigin(config, display.displayID, Int32(x), Int32(y))
        CGConfigureDisplayOrigin(config, sidecarID, Int32(sx), Int32(sy))
        let result = CGCompleteDisplayConfiguration(config, .forSession)
        sidecarBounds = CGDisplayBounds(sidecarID)
        Log.info("随航竖屏：排列 虚拟屏 → (\(Int(x)),\(Int(y)))，随航 → (\(Int(sx)),\(Int(sy)))，结果 \(result.rawValue)，随航现在 \(sidecarBounds)")
        if let screen = sidecarScreen() { window?.setFrame(screen.frame, display: true) }
        layoutLayer()
    }

    private func restoreArrangement() {
        guard let saved = originalSidecarOrigin else { return }
        originalSidecarOrigin = nil
        guard Self.findSidecar() == sidecarID else { return }
        // 还原到主屏旁边（原位置若已不贴着主屏，就按左右侧贴边居中）
        let main = CGDisplayBounds(CGMainDisplayID()), s = CGDisplayBounds(sidecarID)
        let adjacent = saved.x == main.maxX || saved.x + s.width == main.minX
        let origin = adjacent ? saved : CGPoint(x: saved.x < main.midX ? main.minX - s.width : main.maxX, y: (main.midY - s.height / 2).rounded())
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else { return }
        CGConfigureDisplayOrigin(config, sidecarID, Int32(origin.x), Int32(origin.y))
        CGCompleteDisplayConfiguration(config, .forSession)
    }

    // MARK: - 把落到随航屏上的窗口搬到竖屏

    private func rescueWindows() {
        guard active, let display, AXIsProcessTrusted() else { return }
        let s = sidecarBounds, v = display.bounds
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return }
        let me = ProcessInfo.processInfo.processIdentifier
        for info in list {
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != me,
                  let dict = info[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: dict),
                  frame.width > 40, frame.height > 40,
                  s.contains(CGPoint(x: frame.midX, y: frame.midY)) else { continue }
            moveWindow(pid: pid, frame: frame, into: v)
        }
    }

    private func moveWindow(pid: pid_t, frame: CGRect, into v: CGRect) {
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return }
        for w in windows {
            var posRef: CFTypeRef?, sizeRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(w, kAXPositionAttribute as CFString, &posRef) == .success,
                  AXUIElementCopyAttributeValue(w, kAXSizeAttribute as CFString, &sizeRef) == .success else { continue }
            var pos = CGPoint.zero, size = CGSize.zero
            AXValueGetValue(posRef as! AXValue, .cgPoint, &pos)
            AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
            guard abs(pos.x - frame.minX) < 4, abs(pos.y - frame.minY) < 4 else { continue }
            // 全屏窗口挪不动：先退出全屏，下一轮再搬
            var fs: CFTypeRef?
            if AXUIElementCopyAttributeValue(w, "AXFullScreen" as CFString, &fs) == .success, (fs as? Bool) == true {
                AXUIElementSetAttributeValue(w, "AXFullScreen" as CFString, kCFBooleanFalse)
                Log.info("随航竖屏：进程 \(pid) 的全屏窗口落在随航屏上，先退出全屏")
                return
            }
            var newSize = CGSize(width: min(size.width, v.width), height: min(size.height, v.height - 30))
            var newPos = CGPoint(x: v.minX + (v.width - newSize.width) / 2, y: v.minY + 30 + max(0, (v.height - 30 - newSize.height) / 2))
            if let p = AXValueCreate(.cgPoint, &newPos) { AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString, p) }
            if let z = AXValueCreate(.cgSize, &newSize) { AXUIElementSetAttributeValue(w, kAXSizeAttribute as CFString, z) }
            Log.info("随航竖屏：把进程 \(pid) 的窗口从随航屏搬到竖屏")
            return
        }
    }

    func flip() {
        Self.clockwise.toggle()
        layoutLayer()
    }

    private func setStatus(_ s: String) {
        status = s
        if !s.isEmpty { Log.info("随航竖屏：\(s)") }
        onChange?()
    }

    /// 触摸屏驱动在本模式开启之后才启用好：换成原生触摸屏
    @objc private func driverActivated() {
        guard active, let display, injector != nil, !(injector is HIDTouchscreenInjector) else { return }
        injector?.reset()
        injector = InjectorFactory.make(displayID: display.displayID, displayUUID: display.uuidString, feedback: { _ in })
        Log.info("随航竖屏：驱动已启用，触控后端换成 \(injector?.label ?? "-")")
    }

    /// 退出时还原显示器排列
    @objc private func appWillTerminate() { stop() }

    @objc private func screensChanged() {
        guard active else { return }
        guard let sid = Self.findSidecar() else { stop(); setStatus("随航已断开"); return }
        sidecarID = sid
        sidecarBounds = CGDisplayBounds(sid)
        if let screen = sidecarScreen() { window?.setFrame(screen.frame, display: true) }
        layoutLayer()
        if let display { injector?.retarget(displayID: display.displayID) }
    }

    // MARK: - 随航屏上的窗口

    private func sidecarScreen() -> NSScreen? {
        NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == sidecarID }
    }

    private func makeWindow() {
        guard let screen = sidecarScreen() else { return }
        let w = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        w.level = .screenSaver
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        w.backgroundColor = .black
        w.isOpaque = true
        w.hasShadow = false
        // 不能点击穿透：随航的触控只交给手指下的窗口，这层要自己接住触控。
        // 之前接住了却没挂识别器，触控被吞掉，还让随航卡在「拖动中」（整个系统拖不动窗口，断开随航才恢复）。
        // Mac 的光标被挡在随航屏外，所以这层接不到鼠标点击。
        w.ignoresMouseEvents = false
        w.isReleasedWhenClosed = false
        let view = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor
        imageLayer.contentsGravity = .resize
        imageLayer.actions = ["contents": NSNull(), "transform": NSNull(), "bounds": NSNull(), "position": NSNull()]
        view.layer?.addSublayer(imageLayer)
        let recognizer = SidecarTouchRecognizer(target: nil, action: nil)
        recognizer.onTouches = { [weak self] in self?.touches($0) }
        view.addGestureRecognizer(recognizer)
        w.contentView = view
        w.setFrame(screen.frame, display: true)
        w.orderFrontRegardless()
        window = w
        layoutLayer()
    }

    private func layoutLayer() {
        guard let view = window?.contentView else { return }
        let size = view.bounds.size
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.bounds = CGRect(x: 0, y: 0, width: size.height, height: size.width)
        imageLayer.position = CGPoint(x: size.width / 2, y: size.height / 2)
        // AppKit 图层坐标 y 朝上，负角度是顺时针
        imageLayer.setAffineTransform(CGAffineTransform(rotationAngle: Self.clockwise ? -.pi / 2 : .pi / 2))
        CATransaction.commit()
    }

    // MARK: - 随航触点

    /// 横屏里的归一化坐标（左上角原点）→ 竖屏里的归一化坐标
    static func rotate(_ u: CGFloat, _ w: CGFloat, clockwise cw: Bool) -> CGPoint {
        CGPoint(x: cw ? w : 1 - w, y: cw ? 1 - u : u)
    }

    private func touches(_ contacts: [SidecarTouchRecognizer.Contact]) {
        guard active, let injector else { return }
        lastTouchTime = ProcessInfo.processInfo.systemUptime
        let cw = Self.clockwise
        let mapped = contacts.map { c -> TouchContact in
            let p = Self.rotate(c.x, c.y, clockwise: cw)
            return TouchContact(id: c.id, phase: c.phase, kind: .finger, x: Float(min(max(p.x, 0), 0.9999)), y: Float(min(max(p.y, 0), 0.9999)),
                                pressure: 1, altitude: 0, azimuth: 0, radius: 0)
        }
        if touchCount == 0 { Log.info("随航竖屏：收到第一次随航原生触点 \(contacts.map { "#\($0.id) \($0.phase) (\(String(format: "%.2f", $0.x)),\(String(format: "%.2f", $0.y)))" })") }
        touchCount += contacts.filter { $0.phase == .began }.count
        injector.handle(TouchPacket(timestamp: monotonicNs(), contacts: mapped))
    }

    // MARK: - 采集

    private func startCapture(pixelWidth: Int, pixelHeight: Int) async {
        guard let display else { return }
        var target: SCDisplay?
        for _ in 0..<20 {
            if let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false) {
                target = content.displays.first { $0.displayID == display.displayID }
            }
            if target != nil { break }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        guard let target, active else { await MainActor.run { setStatus("系统尚未列出竖屏虚拟显示器") }; return }
        let c = SCStreamConfiguration()
        c.width = pixelWidth
        c.height = pixelHeight
        c.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        c.pixelFormat = kCVPixelFormatType_32BGRA
        c.colorSpaceName = CGColorSpace.sRGB
        c.showsCursor = true
        c.queueDepth = 5
        c.capturesAudio = false
        let s = SCStream(filter: SCContentFilter(display: target, excludingWindows: []), configuration: c, delegate: self)
        do {
            try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: captureQueue)
            try await s.startCapture()
            await MainActor.run {
                if self.active { self.stream = s } else { Task { try? await s.stopCapture() } }
            }
        } catch {
            await MainActor.run { setStatus("录屏失败：\(error.localizedDescription)") }
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let pb = sampleBuffer.imageBuffer,
              let surface = CVPixelBufferGetIOSurface(pb)?.takeUnretainedValue() else { return }
        DispatchQueue.main.async {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.imageLayer.contents = surface
            CATransaction.commit()
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { if self.active { self.setStatus("录屏中断：\(error.localizedDescription)") } }
    }

    // MARK: - 事件换算

    private func installTap() {
        var mask: CGEventMask = 0
        for t in [1, 2, 3, 4, 5, 6, 7, 22, 25, 26, 27, 29, 30, 31, 18, 19, 20, 32] as [UInt64] { mask |= 1 << t }
        let callback: CGEventTapCallBack = { _, type, event, info in
            // userInfo 非空表示硬件层
            // 返回 true 表示已换成副本另行投递，原事件丢掉
            if SidecarPortrait.shared.handle(type, event, hid: info != nil) { return nil }
            return Unmanaged.passUnretained(event)
        }
        for location in [CGEventTapLocation.cghidEventTap] {
            let hid = location == .cghidEventTap
            guard let port = CGEvent.tapCreate(tap: location, place: .headInsertEventTap, options: .defaultTap,
                                               eventsOfInterest: mask, callback: callback,
                                               userInfo: hid ? UnsafeMutableRawPointer(bitPattern: 1) : nil) else {
                Log.info("随航竖屏：\(hid ? "硬件层" : "会话层")监听建立失败")
                continue
            }
            let source = CFMachPortCreateRunLoopSource(nil, port, 0)!
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            CGEvent.tapEnable(tap: port, enable: true)
            taps.append((port, source))
            Log.info("随航竖屏：\(hid ? "硬件层" : "会话层")事件换算已接入")
        }
        if taps.isEmpty { setStatus("无法监听事件：请确认已授予「辅助功能」权限") }
    }

    private func handle(_ type: CGEventType, _ e: CGEvent, hid: Bool) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            for t in taps { CGEvent.tapEnable(tap: t.port, enable: true) }
            return false
        }
        guard active, let display else { return false }
        let p = e.location
        let s = sidecarBounds
        let isMouse = (1...7).contains(type.rawValue) || (25...27).contains(type.rawValue)
        guard s.contains(p) else {
            if isMouse { lastCursor = p }
            return false
        }
        // 鼠标或触控板从相邻的那一小段边挤进随航屏：当成撞墙，拦掉。
        // 随航的触控是从别处直接跳过来的，离上一次光标位置远，不受影响。
        // （硬件层回调里系统光标已经挪到新位置了，所以用自己记的上一次位置）
        if hid, [5, 6, 7, 27].contains(type.rawValue), hypot(p.x - lastCursor.x, p.y - lastCursor.y) < 40 {
            // 拦掉事件挡不住系统光标，还得把光标拉回墙这边
            CGWarpMouseCursorPosition(lastCursor)
            CGAssociateMouseAndMouseCursorPosition(1)
            return true
        }
        // 正在用随航原生触点时，随航屏上冒出来的鼠标事件是系统的模拟，已经由识别器那边处理过了，丢掉免得点两次
        if ProcessInfo.processInfo.systemUptime - lastTouchTime < 0.6 { return true }
        let v = display.bounds
        // 归一化的横屏坐标 → 竖屏坐标（都以左上角为原点）
        let cw = Self.clockwise
        let r = Self.rotate((p.x - s.minX) / s.width, (p.y - s.minY) / s.height, clockwise: cw)
        let target = CGPoint(x: v.minX + min(max(r.x, 0), 0.9999) * v.width, y: v.minY + min(max(r.y, 0), 0.9999) * v.height)
        remapped += 1
        switch type.rawValue {
        case 1, 2, 3, 4, 5, 6, 7, 25, 26, 27:
            // 原地改硬件层的鼠标事件，系统仍会按相对位移（带加速）去挪光标，落点不准。
            // 所以拦下原事件，复制一份改好落点再投到会话层；点击次数、压力等字段都随副本保留。
            guard let copy = e.copy() else { e.location = target; return false }
            copy.location = target
            copy.setIntegerValueField(.mouseEventDeltaX, value: 0)
            copy.setIntegerValueField(.mouseEventDeltaY, value: 0)
            copy.post(tap: .cgSessionEventTap)
            lastCursor = target
            return true
        case 22:
            e.location = target
            rotateScroll(e, clockwise: cw)
        default:
            e.location = target
        }
        return false
    }

    /// 横屏里手指的位移向量 (dx, dy) 转到竖屏：顺时针时 (dy, -dx)，逆时针时 (-dy, dx)。
    /// 滚动的 Axis1 是竖直分量、Axis2 是水平分量。
    private func rotateScroll(_ e: CGEvent, clockwise cw: Bool) {
        func swapInt(_ vertical: CGEventField, _ horizontal: CGEventField) {
            let dy = e.getIntegerValueField(vertical), dx = e.getIntegerValueField(horizontal)
            e.setIntegerValueField(horizontal, value: cw ? dy : -dy)
            e.setIntegerValueField(vertical, value: cw ? -dx : dx)
        }
        func swapDouble(_ vertical: CGEventField, _ horizontal: CGEventField) {
            let dy = e.getDoubleValueField(vertical), dx = e.getDoubleValueField(horizontal)
            e.setDoubleValueField(horizontal, value: cw ? dy : -dy)
            e.setDoubleValueField(vertical, value: cw ? -dx : dx)
        }
        // 系统会用后写的字段推算前面的，所以按「行 → 定点 → 像素」的顺序写
        swapInt(.scrollWheelEventDeltaAxis1, .scrollWheelEventDeltaAxis2)
        swapDouble(.scrollWheelEventFixedPtDeltaAxis1, .scrollWheelEventFixedPtDeltaAxis2)
        swapInt(.scrollWheelEventPointDeltaAxis1, .scrollWheelEventPointDeltaAxis2)
    }
}
