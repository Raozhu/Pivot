// 诊断工具：通过 USB 把 iPad 屏幕当作采集设备抓一帧存成 PNG（与 QuickTime 录制 iPad 屏幕同一机制）。
// 用法：swift scripts/padshot.swift 输出.png [等待秒数]
// 注意：开始抓屏会让 iPad 的 USB 重新枚举，正在进行的 Pivot 会话会断开并自动重连，所以默认等 5 秒再取帧。
// 需要终端有「相机」权限。
import AVFoundation
import CoreMediaIO
import AppKit

var prop = CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyAllowScreenCaptureDevices),
                                     mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                     mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
var allow: UInt32 = 1
CMIOObjectSetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &prop, 0, nil, UInt32(MemoryLayout<UInt32>.size), &allow)

let status = AVCaptureDevice.authorizationStatus(for: .video)
print("相机授权状态：\(status.rawValue)（0 未决定 1 受限 2 拒绝 3 已授权）")

final class Grabber: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let output: String
    let notBefore: Date
    init(output: String, wait: Double) { self.output = output; notBefore = Date().addingTimeInterval(wait) }
    func captureOutput(_ o: AVCaptureOutput, didOutput sb: CMSampleBuffer, from c: AVCaptureConnection) {
        guard Date() >= notBefore, let pb = sb.imageBuffer else { return }
        let image = CIImage(cvPixelBuffer: pb)
        let rep = NSBitmapImageRep(ciImage: image)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: output))
        print("已保存 \(CVPixelBufferGetWidth(pb))x\(CVPixelBufferGetHeight(pb)) → \(output)")
        exit(0)
    }
}

// 屏幕采集设备出现需要一点时间
var device: AVCaptureDevice?
for _ in 0..<20 {
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    let found = AVCaptureDevice.DiscoverySession(deviceTypes: [.external], mediaType: .muxed, position: .unspecified).devices
    if let d = found.first { device = d; break }
}
guard let device else { print("没有找到 iPad 屏幕采集设备"); exit(1) }
print("设备：\(device.localizedName)")
let session = AVCaptureSession()
guard let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else { print("无法打开设备（可能缺少相机权限）"); exit(2) }
session.addInput(input)
let out = AVCaptureVideoDataOutput()
let wait = CommandLine.arguments.count > 2 ? Double(CommandLine.arguments[2]) ?? 5 : 5
let grabber = Grabber(output: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "padshot.png", wait: wait)
out.setSampleBufferDelegate(grabber, queue: DispatchQueue(label: "grab"))
session.addOutput(out)
session.startRunning()
RunLoop.main.run(until: Date().addingTimeInterval(wait + 8))
print("没有拿到画面")
exit(3)
