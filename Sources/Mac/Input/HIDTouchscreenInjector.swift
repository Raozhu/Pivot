import Foundation
import CoreGraphics

/// 原生路线：注册一块绑定到虚拟显示器的 10 点触摸屏，由 macOS 27 像对待随航一样原生处理手指。
///
/// 做法照 WiredPad（MIT，https://github.com/takpika/WiredPad）：
/// 1. 本进程用 IOHIDUserDevice 建一块虚拟 HID 触摸屏，把显示器编号放在 `CGDirectDisplayID`、
///    显示器 UUID 放在 `SerialNumber` 里；
/// 2. Pivot 自带的 DriverKit 驱动（`Driver/`）匹配这块设备，把 UUID 以 `displayUUID` 写到自己的触控服务上，
///    再把报告变成数字化仪触控事件。只写在虚拟设备上的话，WindowServer 会当成「不支持的服务」丢掉。
///
/// 需要 `com.apple.developer.hid.virtual.device` 和 DriverKit 权限。免费开发团队拿不到，
/// 只能关掉 SIP 和 AMFI 后自签名（见 scripts/build.sh）。驱动没启用时不会用到这里。
///
/// 只接手指。Pencil、悬停、外接触控板和鼠标仍交给合成手势。
final class HIDTouchscreenInjector: TouchInjector {
    static let maxContacts = 10
    static let vendorID = 0x5056
    static let productID = 3

    let label = "原生触摸屏"
    private let device: IOHIDUserDevice
    private let queue = DispatchQueue(label: "pivot.hid", qos: .userInteractive)
    private let fallback: SyntheticInjector
    /// 每个槽位对应驱动里的一个触点编号（0…9）
    private struct Slot { var contactID: UInt8; var x: Double; var y: Double }
    private var slots: [Slot?] = Array(repeating: nil, count: maxContacts)
    private var reports = 0

    /// 与驱动约定的报告格式（同 WiredPad）：报告 1，10 个触点，各含标志、编号、x、y（0…32767）
    private static var descriptor: Data {
        var d: [UInt8] = [0x05, 0x0D, 0x09, 0x04, 0xA1, 0x01, 0x85, 0x01]
        for _ in 0..<maxContacts {
            d += [
                0x05, 0x0D, 0x09, 0x22, 0xA1, 0x02,
                0x09, 0x42, 0x09, 0x32, 0x15, 0x00, 0x25, 0x01,
                0x75, 0x01, 0x95, 0x02, 0x81, 0x02,
                0x75, 0x06, 0x95, 0x01, 0x81, 0x03,
                0x09, 0x51, 0x15, 0x00, 0x25, 0x09,
                0x75, 0x08, 0x95, 0x01, 0x81, 0x02,
                0x05, 0x01, 0x09, 0x30, 0x09, 0x31,
                0x16, 0x00, 0x00, 0x26, 0xFF, 0x7F,
                0x75, 0x10, 0x95, 0x02, 0x81, 0x02,
                0xC0,
            ]
        }
        d += [
            0x05, 0x0D, 0x09, 0x54, 0x15, 0x00, 0x25, 0x0A,
            0x75, 0x08, 0x95, 0x01, 0x81, 0x02,
            0x09, 0x55, 0x25, 0x0A, 0xB1, 0x02, 0xC0,
        ]
        return Data(d)
    }

    init?(displayID: CGDirectDisplayID, displayUUID: String, fallback: SyntheticInjector) {
        let properties: [String: Any] = [
            "ReportDescriptor": Self.descriptor,
            "VendorID": Self.vendorID,
            "ProductID": Self.productID,
            "Product": "Pivot Touchscreen",
            "Manufacturer": "Pivot",
            "SerialNumber": displayUUID,
            "CGDirectDisplayID": NSNumber(value: displayID),
        ]
        guard let device = IOHIDUserDeviceCreateWithProperties(kCFAllocatorDefault, properties as CFDictionary, 0) else { return nil }
        self.device = device
        self.fallback = fallback
        IOHIDUserDeviceRegisterGetReportBlock(device) { _, _, report, length in
            // 报告 1 的特性字段：最多 10 个触点
            guard length.pointee >= 2 else { return kIOReturnUnsupported }
            report[0] = 1
            report[1] = UInt8(Self.maxContacts)
            length.pointee = 2
            return kIOReturnSuccess
        }
        IOHIDUserDeviceSetDispatchQueue(device, queue)
        IOHIDUserDeviceActivate(device)
        Log.info("原生触摸屏：已注册，绑定显示器 \(displayID)（\(displayUUID)）")
    }

    deinit { IOHIDUserDeviceCancel(device) }

    func retarget(displayID: CGDirectDisplayID) { fallback.retarget(displayID: displayID) }

    func pointerScroll(dx: Double, dy: Double, phase: UInt8) { fallback.pointerScroll(dx: dx, dy: dy, phase: phase) }

    func handle(_ packet: TouchPacket) {
        let fingers = packet.contacts.filter { $0.kind == .finger }
        if fingers.count != packet.contacts.count {
            fallback.handle(TouchPacket(timestamp: packet.timestamp, contacts: packet.contacts.filter { $0.kind != .finger }))
        }
        guard !fingers.isEmpty else { return }
        queue.async { [self] in
            var lifted: [Int] = []
            for c in fingers {
                let index = slots.firstIndex { $0?.contactID == c.id } ?? slots.firstIndex { $0 == nil }
                guard let i = index else { continue }
                if c.phase == .ended || c.phase == .cancelled {
                    if slots[i] != nil { lifted.append(i) }
                } else {
                    slots[i] = Slot(contactID: c.id, x: Double(c.x), y: Double(c.y))
                }
            }
            for i in lifted { slots[i] = nil }
            sendReport()
        }
    }

    func reset() {
        fallback.reset()
        queue.async { [self] in
            guard slots.contains(where: { $0 != nil }) else { return }
            slots = Array(repeating: nil, count: Self.maxContacts)
            sendReport()
        }
    }

    /// 抬起的手指只要不再出现在报告里，驱动就会按上一次的位置补发抬起
    private func sendReport() {
        var report = [UInt8](repeating: 0, count: 2 + Self.maxContacts * 6)
        report[0] = 1
        for (i, slot) in slots.enumerated() {
            guard let slot else { continue }
            let o = 1 + i * 6
            report[o] = 3
            report[o + 1] = UInt8(i)
            let x = UInt16((max(0, min(1, slot.x)) * 32767).rounded())
            let y = UInt16((max(0, min(1, slot.y)) * 32767).rounded())
            report[o + 2] = UInt8(truncatingIfNeeded: x); report[o + 3] = UInt8(truncatingIfNeeded: x >> 8)
            report[o + 4] = UInt8(truncatingIfNeeded: y); report[o + 5] = UInt8(truncatingIfNeeded: y >> 8)
            report[report.count - 1] += 1
        }
        let r = IOHIDUserDeviceHandleReportWithTimeStamp(device, mach_absolute_time(), report, report.count)
        reports += 1
        if reports <= 3 || r != kIOReturnSuccess { Log.info("原生触摸屏：第 \(reports) 份报告，\(report.last ?? 0) 个触点，结果 \(r)") }
    }
}
