import Foundation
import VideoToolbox
import CoreMedia

/// 硬件 HEVC 低延迟编码：不重排帧、不缓冲，关键帧只在需要时产生。
final class VideoEncoder {
    struct Output {
        var data: Data
        var isKey: Bool
        /// 仅关键帧携带：参数集负载
        var format: Data?
        var index: UInt32
        var captureNs: UInt64
        var encodeMicros: UInt32
    }

    private var session: VTCompressionSession?
    private let lock = NSLock()
    private var wantsKeyframe = true
    private var frameIndex: UInt32 = 0
    let width: Int
    let height: Int
    let fps: Int
    private(set) var bitrate: Int
    private(set) var lowLatencyRateControl = false

    var onOutput: ((Output) -> Void)?

    static func recommendedBitrate(width: Int, height: Int, fps: Int) -> Int {
        // 有线带宽充裕，按每像素每帧约 0.3 bit 给，保证文字边缘干净
        let raw = Double(width * height * fps) * 0.3
        return Int(min(160_000_000, max(24_000_000, raw)))
    }

    /// - Parameter bitrate: 目标码率；不给则按有线的充裕带宽估算
    init?(width: Int, height: Int, fps: Int, bitrate requested: Int? = nil) {
        self.width = width
        self.height = height
        self.fps = fps
        bitrate = requested ?? Self.recommendedBitrate(width: width, height: height, fps: fps)

        func create(lowLatency: Bool) -> VTCompressionSession? {
            var spec: [CFString: Any] = [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true]
            if lowLatency { spec[kVTVideoEncoderSpecification_EnableLowLatencyRateControl] = true }
            var s: VTCompressionSession?
            let status = VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height),
                                                    codecType: kCMVideoCodecType_HEVC,
                                                    encoderSpecification: spec as CFDictionary,
                                                    imageBufferAttributes: nil, compressedDataAllocator: nil,
                                                    outputCallback: nil, refcon: nil, compressionSessionOut: &s)
            return status == noErr ? s : nil
        }

        if let s = create(lowLatency: true) {
            session = s
            lowLatencyRateControl = true
        } else if let s = create(lowLatency: false) {
            session = s
        } else {
            return nil
        }
        guard let session else { return nil }

        func set(_ key: CFString, _ value: Any) { VTSessionSetProperty(session, key: key, value: value as CFTypeRef) }
        set(kVTCompressionPropertyKey_RealTime, true)
        set(kVTCompressionPropertyKey_AllowFrameReordering, false)
        // 编码器不攒帧：来一帧出一帧，省掉排队延迟
        set(kVTCompressionPropertyKey_MaxFrameDelayCount, 0)
        set(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_HEVC_Main_AutoLevel)
        set(kVTCompressionPropertyKey_AverageBitRate, bitrate)
        set(kVTCompressionPropertyKey_ExpectedFrameRate, fps)
        set(kVTCompressionPropertyKey_MaxKeyFrameInterval, 36_000)
        set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, 600)
        set(kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, true)
        set(kVTCompressionPropertyKey_ColorPrimaries, kCVImageBufferColorPrimaries_ITU_R_709_2)
        set(kVTCompressionPropertyKey_TransferFunction, kCVImageBufferTransferFunction_sRGB)
        set(kVTCompressionPropertyKey_YCbCrMatrix, kCVImageBufferYCbCrMatrix_ITU_R_709_2)
        VTCompressionSessionPrepareToEncodeFrames(session)
    }

    /// 运行中调整目标码率（无线自适应用）
    func setBitrate(_ value: Int) {
        guard let session, value != bitrate else { return }
        bitrate = value
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: value as CFTypeRef)
    }

    func requestKeyframe() {
        lock.lock(); wantsKeyframe = true; lock.unlock()
    }

    func encode(_ pixelBuffer: CVPixelBuffer, pts: CMTime, captureNs: UInt64) {
        guard let session else { return }
        lock.lock()
        let key = wantsKeyframe
        wantsKeyframe = false
        let index = frameIndex
        frameIndex &+= 1
        lock.unlock()

        let props: CFDictionary? = key ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        let started = monotonicNs()
        let status = VTCompressionSessionEncodeFrame(session, imageBuffer: pixelBuffer, presentationTimeStamp: pts,
                                                     duration: .invalid, frameProperties: props, infoFlagsOut: nil) { [weak self] status, _, sample in
            guard let self, status == noErr, let sample, sample.dataReadiness == .ready else {
                self?.requestKeyframe()
                return
            }
            self.deliver(sample, index: index, captureNs: captureNs, started: started)
        }
        if status != noErr { requestKeyframe() }
    }

    private func deliver(_ sample: CMSampleBuffer, index: UInt32, captureNs: UInt64, started: UInt64) {
        guard let block = sample.dataBuffer else { return }
        var isKey = true
        if let arr = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]],
           let notSync = arr.first?[kCMSampleAttachmentKey_NotSync] as? Bool {
            isKey = !notSync
        }
        let length = CMBlockBufferGetDataLength(block)
        var data = Data(count: length)
        let copied = data.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
        guard copied == kCMBlockBufferNoErr else { return }

        var format: Data?
        if isKey, let desc = sample.formatDescription {
            var count = 0
            var nalLen: Int32 = 4
            CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(desc, parameterSetIndex: 0, parameterSetPointerOut: nil,
                                                               parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: &nalLen)
            var sets: [Data] = []
            for i in 0..<count {
                var ptr: UnsafePointer<UInt8>?
                var size = 0
                if CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(desc, parameterSetIndex: i, parameterSetPointerOut: &ptr,
                                                                      parameterSetSizeOut: &size, parameterSetCountOut: nil,
                                                                      nalUnitHeaderLengthOut: nil) == noErr, let ptr {
                    sets.append(Data(bytes: ptr, count: size))
                }
            }
            format = FormatPayload.encode(nalLengthSize: Int(nalLen), parameterSets: sets)
        }
        let micros = UInt32(min(UInt64(UInt32.max), (monotonicNs() - started) / 1000))
        onOutput?(Output(data: data, isKey: isKey, format: format, index: index, captureNs: captureNs, encodeMicros: micros))
    }

    func invalidate() {
        guard let session else { return }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(session)
        self.session = nil
    }

    deinit { invalidate() }
}
