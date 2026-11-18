import Foundation
import ScreenCaptureKit
import AVFoundation

/// 采集 Mac 的系统声音，编成 Opus 小包交给发送回调。
/// 用一个独立的 ScreenCaptureKit 流只取声音，和画面采集互不影响（换分辨率、换显示模式都不打断声音）。
final class AudioStreamer: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "pivot.audio", qos: .userInteractive)
    private var encoder: OpusEncoder?
    private var seq: UInt32 = 0
    /// 攒满 480 帧再编一包（queue 上）
    private var pending: AVAudioPCMBuffer?
    private var running = false

    /// 在 queue 上回调：已打包好的负载（u32 序号 + Opus）
    var onPacket: ((Data) -> Void)?

    func start() async throws {
        guard !running else { return }
        running = true
        encoder = OpusEncoder()
        pending = AVAudioPCMBuffer(pcmFormat: AudioCodec.pcmFormat, frameCapacity: AudioCodec.frameSize)
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first else {
            running = false
            throw NSError(domain: "Pivot", code: 2, userInfo: [NSLocalizedDescriptionKey: "找不到显示器"])
        }
        let c = SCStreamConfiguration()
        c.capturesAudio = true
        c.sampleRate = Int(AudioCodec.sampleRate)
        c.channelCount = Int(AudioCodec.channels)
        c.excludesCurrentProcessAudio = true
        // 画面只是附带的：取最小尺寸、最低帧率
        c.width = 2
        c.height = 2
        c.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        c.queueDepth = 3
        let stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: c, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() async {
        running = false
        guard let stream else { return }
        self.stream = nil
        try? await stream.stopCapture()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, running, sampleBuffer.isValid,
              let desc = sampleBuffer.formatDescription,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc)?.pointee,
              asbd.mFormatID == kAudioFormatLinearPCM, asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0, asbd.mBitsPerChannel == 32 else { return }
        let nonInterleaved = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        let channels = Int(asbd.mChannelsPerFrame)
        try? sampleBuffer.withAudioBufferList { list, _ in
            let frames = sampleBuffer.numSamples
            guard frames > 0, channels > 0 else { return }
            // 取出左右声道的指针（单声道时左右相同）
            var left: UnsafePointer<Float>, right: UnsafePointer<Float>, stride = 1
            if nonInterleaved {
                guard let l = list[0].mData?.assumingMemoryBound(to: Float.self) else { return }
                left = UnsafePointer(l)
                right = list.count > 1 ? UnsafePointer(list[1].mData!.assumingMemoryBound(to: Float.self)) : left
            } else {
                guard let p = list[0].mData?.assumingMemoryBound(to: Float.self) else { return }
                left = UnsafePointer(p)
                right = channels > 1 ? UnsafePointer(p + 1) : left
                stride = channels
            }
            append(left: left, right: right, stride: stride, frames: frames)
        }
    }

    private func append(left: UnsafePointer<Float>, right: UnsafePointer<Float>, stride: Int, frames: Int) {
        guard let pending, let encoder, let dst = pending.floatChannelData else { return }
        var i = 0
        while i < frames {
            let at = Int(pending.frameLength)
            let n = min(frames - i, Int(AudioCodec.frameSize) - at)
            for k in 0..<n {
                dst[0][at + k] = left[(i + k) * stride]
                dst[1][at + k] = right[(i + k) * stride]
            }
            pending.frameLength = AVAudioFrameCount(at + n)
            i += n
            if pending.frameLength == AudioCodec.frameSize {
                if let opus = encoder.encode(pending) {
                    seq &+= 1
                    onPacket?(AudioCodec.packet(seq: seq, opus: opus))
                }
                pending.frameLength = 0
            }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        self.stream = nil
        Log.info("声音采集停止：\(error.localizedDescription)")
    }
}
