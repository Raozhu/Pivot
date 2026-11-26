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
        var isRefresh = false
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

    // 长期参考帧（LTR）：编码器给每个参考帧一个令牌，iPad 回执确认收到后把令牌交回编码器。
    // 丢帧时不发关键帧，而是让编码器参照一个已确认的帧编一个 P 帧（实测几百字节，关键帧要几百 KB）
    private(set) var ltrEnabled = false
    private var tokenByIndex: [UInt32: Int] = [:]
    private var pendingAcks: [Int] = []
    private var anyAcked = false
    private var wantsRefresh = false
    private var lastRecoveryNs: UInt64 = 0
    /// 发出去还没被 iPad 确认的刷新帧编号
    private var refreshOutstanding: UInt32?

    var onOutput: ((Output) -> Void)?

    static func recommendedBitrate(width: Int, height: Int, fps: Int) -> Int {
        // 有线带宽充裕，按每像素每帧约 0.3 bit 给，保证文字边缘干净
        let raw = Double(width * height * fps) * 0.3
        return Int(min(160_000_000, max(24_000_000, raw)))
    }

    /// - Parameter bitrate: 目标码率；不给则按有线的充裕带宽估算
    init?(width: Int, height: Int, fps: Int, bitrate requested: Int? = nil, longTermReference: Bool = false) {
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
        if longTermReference, lowLatencyRateControl {
            ltrEnabled = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_EnableLTR, value: kCFBooleanTrue) == noErr
        }
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

    /// 丢帧后恢复：有已确认的长期参考帧就编一个参照它的小 P 帧。
    /// 只有上一次刷新发出后 1 秒内还没被确认、iPad 又来求救（刷新没救回来）才发关键帧
    func requestRecovery() {
        lock.lock(); defer { lock.unlock() }
        let now = monotonicNs()
        let failed = refreshOutstanding != nil && now - lastRecoveryNs < 1_000_000_000
        if ltrEnabled, anyAcked, !failed {
            wantsRefresh = true
        } else {
            wantsKeyframe = true
            refreshOutstanding = nil
        }
        lastRecoveryNs = now
    }

    /// iPad 确认收到并送显了这一帧
    func acknowledge(index: UInt32) {
        guard ltrEnabled else { return }
        lock.lock(); defer { lock.unlock() }
        if let t = tokenByIndex.removeValue(forKey: index) { pendingAcks.append(t); anyAcked = true }
        if let r = refreshOutstanding, Int32(bitPattern: index &- r) >= 0 { refreshOutstanding = nil }
    }

    func encode(_ pixelBuffer: CVPixelBuffer, pts: CMTime, captureNs: UInt64) {
        guard let session else { return }
        lock.lock()
        let key = wantsKeyframe
        wantsKeyframe = false
        let refresh = !key && wantsRefresh
        wantsRefresh = false
        let acks = pendingAcks
        pendingAcks.removeAll()
        if key { anyAcked = false; tokenByIndex.removeAll() }
        lock.unlock()

        var options: [CFString: Any] = [:]
        if key { options[kVTEncodeFrameOptionKey_ForceKeyFrame] = true }
        if refresh { options[kVTEncodeFrameOptionKey_ForceLTRRefresh] = true }
        if !acks.isEmpty { options[kVTEncodeFrameOptionKey_AcknowledgedLTRTokens] = acks }
        let props: CFDictionary? = options.isEmpty ? nil : options as CFDictionary
        let started = monotonicNs()
        let status = VTCompressionSessionEncodeFrame(session, imageBuffer: pixelBuffer, presentationTimeStamp: pts,
                                                     duration: .invalid, frameProperties: props, infoFlagsOut: nil) { [weak self] status, _, sample in
            guard let self else { return }
            // 码率控制主动跳过的帧（没出错、只是没有输出）：后面的帧不会参考它，不需要关键帧，也不占编号。
            // 以前编号在编码前就分好，跳过的帧在编号上留下空洞，iPad 当成网络丢帧去等关键帧，原画时会卡死
            guard status == noErr else { self.requestKeyframe(); return }
            guard let sample, sample.dataReadiness == .ready else { return }
            self.deliver(sample, captureNs: captureNs, started: started, refresh: refresh)
        }
        if status != noErr { requestKeyframe() }
    }

    private func deliver(_ sample: CMSampleBuffer, captureNs: UInt64, started: UInt64, refresh: Bool) {
        guard let block = sample.dataBuffer else { return }
        var isKey = true
        let att = (CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]])?.first
        if let notSync = att?[kCMSampleAttachmentKey_NotSync] as? Bool { isKey = !notSync }
        let token = att?[kVTSampleAttachmentKey_RequireLTRAcknowledgementToken] as? Int
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
        // 编号只给真正输出的帧，保证连续
        lock.lock()
        let index = frameIndex
        frameIndex &+= 1
        if refresh && !isKey { refreshOutstanding = index }
        if let token {
            tokenByIndex[index] = token
            if tokenByIndex.count > 240 { tokenByIndex = tokenByIndex.filter { index &- $0.key < 120 } }
        }
        lock.unlock()
        onOutput?(Output(data: data, isKey: isKey, format: format, index: index, captureNs: captureNs, encodeMicros: micros,
                         isRefresh: refresh && !isKey))
    }

    func invalidate() {
        guard let session else { return }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(session)
        self.session = nil
    }

    deinit { invalidate() }
}
