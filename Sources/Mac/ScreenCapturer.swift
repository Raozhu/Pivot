import Foundation
import ScreenCaptureKit
import CoreMedia
import CoreVideo

/// 用 ScreenCaptureKit 抓取虚拟显示器。画面没变化时系统不会送帧，天然省电。
final class ScreenCapturer: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private let queue: DispatchQueue
    private var displayID: CGDirectDisplayID = 0

    /// - Parameter queue: 帧回调所在的串行队列
    init(queue: DispatchQueue) {
        self.queue = queue
        super.init()
    }

    /// 在采集队列上回调：像素缓冲、显示时间、采集时刻（本机单调时钟纳秒）
    var onFrame: ((CVPixelBuffer, CMTime, UInt64) -> Void)?
    var onStopped: ((Error?) -> Void)?

    private func configuration(width: Int, height: Int, fps: Int) -> SCStreamConfiguration {
        let c = SCStreamConfiguration()
        c.width = width
        c.height = height
        c.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        c.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        c.colorSpaceName = CGColorSpace.sRGB
        c.colorMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_709_2
        c.showsCursor = true
        c.queueDepth = 4
        c.scalesToFit = true
        c.capturesAudio = false
        return c
    }

    func start(displayID: CGDirectDisplayID, width: Int, height: Int, fps: Int) async throws {
        self.displayID = displayID
        // 虚拟显示器刚创建时，可共享内容列表可能还没刷新，稍作重试
        var target: SCDisplay?
        for _ in 0..<20 {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            target = content.displays.first { $0.displayID == displayID }
            if target != nil { break }
            try await Task.sleep(nanoseconds: 150_000_000)
        }
        guard let display = target else {
            throw NSError(domain: "Pivot", code: 1, userInfo: [NSLocalizedDescriptionKey: "系统尚未列出虚拟显示器"])
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let stream = SCStream(filter: filter, configuration: configuration(width: width, height: height, fps: fps), delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
    }

    func update(width: Int, height: Int, fps: Int) async {
        guard let stream else { return }
        try? await stream.updateConfiguration(configuration(width: width, height: height, fps: fps))
    }

    func stop() async {
        guard let stream else { return }
        self.stream = nil
        try? await stream.stopCapture()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid else { return }
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: raw) == .complete,
              let pixelBuffer = sampleBuffer.imageBuffer else { return }
        onFrame?(pixelBuffer, sampleBuffer.presentationTimeStamp, monotonicNs())
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        self.stream = nil
        onStopped?(error)
    }
}
