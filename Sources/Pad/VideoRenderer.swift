import Foundation
import AVFoundation
import CoreMedia
import VideoToolbox

/// 把收到的 HEVC 帧显示出来，收到即显示，不做缓冲。两条路：
/// - 直通：压缩帧直接交给系统的硬件解码显示层（开销最小）。
/// - 超分：自己硬件解码，比画面区域小的帧用苹果的低延迟超分辨率放大后再送显。
///   只在 iOS 26 以上、设备支持、用户没关「超分辨率」时启用。
final class VideoRenderer {
    let layer: AVSampleBufferDisplayLayer
    private var format: CMVideoFormatDescription?
    private var waitingForKey = true
    private let lock = NSLock()

    /// 需要对端补发关键帧
    /// 参数：只要长期参考帧刷新就够（解码器状态还在）
    var onNeedKeyframe: ((Bool) -> Void)?
    /// 解码器状态丢了（清空、出错、换路径），只有真正的关键帧才能接上
    private var needIDR = true
    /// 某个尺寸的第一帧已送显（宽、高）
    var onFirstFrame: ((Int, Int) -> Void)?
    private var announcedSize: (Int, Int)?

    /// 画面区域的像素宽度（决定超分放大到多大），主线程更新
    var targetWidth: Int {
        get { lock.lock(); defer { lock.unlock() }; return _targetWidth }
        set { lock.lock(); _targetWidth = newValue; lock.unlock() }
    }
    private var _targetWidth = 0

    /// 用户的「超分辨率」开关
    var superResolution: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _superResolution }
        set {
            lock.lock()
            if _superResolution != newValue { _superResolution = newValue; pathDirty = true }
            lock.unlock()
        }
    }
    private var _superResolution = false
    private var pathDirty = false
    private var decoded: AnyObject?   // DecodedPath（iOS 26）

    static var superResolutionSupported: Bool {
        if #available(iOS 26.0, *) { return VTLowLatencySuperResolutionScalerConfiguration.isSupported }
        return false
    }

    init(layer: AVSampleBufferDisplayLayer) {
        self.layer = layer
        layer.videoGravity = .resize
    }

    /// - Parameter keepImage: 保留屏幕上的最后一帧（重连时用，避免闪黑）
    func reset(keepImage: Bool = false) {
        format = nil
        waitingForKey = true
        needIDR = true
        announcedSize = nil
        layer.sampleBufferRenderer.flush(removingDisplayedImage: !keepImage, completionHandler: nil)
    }

    /// 有帧丢了、补不回来：之后的帧依赖它，解出来会花屏，所以等下一个关键帧
    func waitForKeyframe() {
        waitingForKey = true
        onNeedKeyframe?(!needIDR)
    }

    func setFormat(_ payload: Data) {
        guard let (nalLength, sets) = FormatPayload.decode(payload), !sets.isEmpty else { return }
        let nsSets = sets.map { $0 as NSData }
        let pointers = nsSets.map { $0.bytes.assumingMemoryBound(to: UInt8.self) }
        let sizes = nsSets.map { $0.length }
        var desc: CMFormatDescription?
        let status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(allocator: nil, parameterSetCount: sets.count,
                                                                         parameterSetPointers: pointers, parameterSetSizes: sizes,
                                                                         nalUnitHeaderLength: Int32(nalLength), extensions: nil,
                                                                         formatDescriptionOut: &desc)
        withExtendedLifetime(nsSets) {}
        guard status == noErr, let desc else { return }
        if let old = format {
            guard !CMFormatDescriptionEqual(old, otherFormatDescription: desc) else { return }
            let a = CMVideoFormatDescriptionGetDimensions(old), b = CMVideoFormatDescriptionGetDimensions(desc)
            // 方向变了（旋转）：清掉旧画面，避免被拉伸。同方向只换编码分辨率就不清，避免闪黑
            if (a.width > a.height) != (b.width > b.height) {
                layer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
            }
        }
        format = desc
    }

    /// 返回是否已送显
    @discardableResult
    func enqueue(_ header: VideoHeader, _ data: Data) -> Bool {
        let renderer = layer.sampleBufferRenderer
        lock.lock()
        let dirty = pathDirty
        pathDirty = false
        let wantSR = _superResolution && Self.superResolutionSupported
        let target = _targetWidth
        lock.unlock()
        if dirty {
            // 换了显示路径：从下一个关键帧重新开始（保留最后一帧，不闪黑）
            renderer.flush(removingDisplayedImage: false, completionHandler: nil)
            if !wantSR { decoded = nil }
            waitingForKey = true
            needIDR = true
        }
        if renderer.status == .failed || renderer.requiresFlushToResumeDecoding {
            renderer.flush()
            waitingForKey = true
            needIDR = true
        }
        guard let format else { onNeedKeyframe?(false); return false }
        if waitingForKey {
            guard header.isKey || (header.isRefresh && !needIDR) else { onNeedKeyframe?(!needIDR); return false }
            waitingForKey = false
            if header.isKey { needIDR = false }
        }
        guard let sample = makeSample(data, format: format, isKey: header.isKey) else { return false }

        var shown = true
        if #available(iOS 26.0, *), wantSR {
            let path = (decoded as? DecodedPath) ?? DecodedPath(layer: layer)
            decoded = path
            if !path.decode(sample, format: format, targetWidth: target) {
                shown = false
                waitingForKey = true
                needIDR = true
                onNeedKeyframe?(false)
            }
        } else {
            renderer.enqueue(sample)
            PadTelemetry.shared.presentedFrame()
        }

        let dims = CMVideoFormatDescriptionGetDimensions(format)
        let sizeNow = (Int(dims.width), Int(dims.height))
        if shown, announcedSize == nil || announcedSize! != sizeNow {
            announcedSize = sizeNow
            onFirstFrame?(sizeNow.0, sizeNow.1)
        }
        return shown
    }

    private func makeSample(_ data: Data, format: CMVideoFormatDescription, isKey: Bool) -> CMSampleBuffer? {
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: data.count, blockAllocator: nil,
                                                 customBlockSource: nil, offsetToData: 0, dataLength: data.count, flags: 0,
                                                 blockBufferOut: &block) == kCMBlockBufferNoErr, let block else { return nil }
        let copied = data.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: data.count) }
        guard copied == kCMBlockBufferNoErr else { return nil }

        var timing = CMSampleTimingInfo(duration: .invalid,
                                        presentationTimeStamp: CMTime(value: CMTimeValue(monotonicNs()), timescale: 1_000_000_000),
                                        decodeTimeStamp: .invalid)
        var size = data.count
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1,
                                        sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1,
                                        sampleSizeArray: &size, sampleBufferOut: &sample) == noErr, let sample else { return nil }
        Self.markImmediate(sample, isKey: isKey)
        return sample
    }

    static func markImmediate(_ sample: CMSampleBuffer, isKey: Bool) {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
              CFArrayGetCount(attachments) > 0 else { return }
        let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
        CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                             Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        if !isKey {
            CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
    }
}

/// 自己解码 + 超分的显示路径
@available(iOS 26.0, *)
private final class DecodedPath {
    private let layer: AVSampleBufferDisplayLayer
    private var decoder: VTDecompressionSession?
    private var decoderFormat: CMVideoFormatDescription?
    private let srQueue = DispatchQueue(label: "pivot.sr.setup", qos: .userInitiated)
    private let displayQueue = DispatchQueue(label: "pivot.display", qos: .userInteractive)

    /// 每种源尺寸一个超分器。模型加载要 200 ms 左右，所以在后台准备，准备好之前的帧直接显示（不放大）
    private final class Scaler {
        let processor = VTFrameProcessor()
        var pool: CVPixelBufferPool?
        var ready = false
        var failed = false
    }
    private var scalers: [String: Scaler] = [:]
    private let lock = NSLock()
    private var inFlight = 0

    init(layer: AVSampleBufferDisplayLayer) { self.layer = layer }

    deinit {
        if let decoder { VTDecompressionSessionInvalidate(decoder) }
        for s in scalers.values { s.processor.endSession() }
    }

    private func makeDecoder(_ format: CMVideoFormatDescription) -> Bool {
        if let decoder { VTDecompressionSessionInvalidate(decoder); self.decoder = nil }
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        var session: VTDecompressionSession?
        guard VTDecompressionSessionCreate(allocator: nil, formatDescription: format, decoderSpecification: nil,
                                           imageBufferAttributes: attrs as CFDictionary, outputCallback: nil,
                                           decompressionSessionOut: &session) == noErr, let session else { return false }
        VTSessionSetProperty(session, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        decoder = session
        decoderFormat = format
        return true
    }

    /// 返回 false 表示解码器出错，需要关键帧
    func decode(_ sample: CMSampleBuffer, format: CMVideoFormatDescription, targetWidth: Int) -> Bool {
        if decoder == nil || decoderFormat == nil || !CMFormatDescriptionEqual(decoderFormat!, otherFormatDescription: format) {
            guard makeDecoder(format) else { return false }
        }
        guard let decoder else { return false }
        let dims = CMVideoFormatDescriptionGetDimensions(format)
        let scaler = scaler(width: Int(dims.width), height: Int(dims.height), targetWidth: targetWidth)
        var callbackFailed = false
        let status = VTDecompressionSessionDecodeFrame(decoder, sampleBuffer: sample, flags: [], infoFlagsOut: nil) { [weak self] status, _, image, _, _ in
            guard status == noErr, let image else { if status != noErr { callbackFailed = true }; return }
            self?.present(image, scaler: scaler)
        }
        if status != noErr || callbackFailed {
            VTDecompressionSessionInvalidate(decoder)
            self.decoder = nil
            decoderFormat = nil
            return false
        }
        return true
    }

    private func scaler(width: Int, height: Int, targetWidth: Int) -> (Scaler, Int, Int)? {
        // 已经和屏幕差不多大就不用超分
        guard targetWidth > 0, Double(width) < Double(targetWidth) * 0.95 else { return nil }
        let key = "\(width)x\(height)"
        lock.lock()
        if let s = scalers[key] {
            let usable = s.ready && !s.failed
            lock.unlock()
            return usable ? (s, 0, 0) : nil
        }
        let s = Scaler()
        scalers[key] = s
        lock.unlock()
        srQueue.async { [weak self] in
            let factors = VTLowLatencySuperResolutionScalerConfiguration.supportedScaleFactors(frameWidth: width, frameHeight: height)
            // 放大到不小于屏幕的最小倍数；都不够就用最大的
            guard let factor = factors.sorted().first(where: { Double(width) * Double($0) >= Double(targetWidth) * 0.97 }) ?? factors.max() else {
                self?.lock.lock(); s.failed = true; self?.lock.unlock()
                print("超分：\(width)x\(height) 不支持")
                return
            }
            let config = VTLowLatencySuperResolutionScalerConfiguration(frameWidth: width, frameHeight: height, scaleFactor: factor)
            do {
                try s.processor.startSession(configuration: config)
                var attrs = config.destinationPixelBufferAttributes
                attrs[kCVPixelBufferWidthKey as String] = Int((Float(width) * factor).rounded())
                attrs[kCVPixelBufferHeightKey as String] = Int((Float(height) * factor).rounded())
                if attrs[kCVPixelBufferPixelFormatTypeKey as String] == nil {
                    attrs[kCVPixelBufferPixelFormatTypeKey as String] = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                }
                var pool: CVPixelBufferPool?
                CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey as String: 4] as CFDictionary, attrs as CFDictionary, &pool)
                self?.lock.lock()
                s.pool = pool
                s.ready = pool != nil
                s.failed = pool == nil
                self?.lock.unlock()
                print("超分：\(width)x\(height) ×\(factor) 已就绪")
            } catch {
                self?.lock.lock(); s.failed = true; self?.lock.unlock()
                print("超分：\(width)x\(height) 启动失败 \(error)")
            }
        }
        return nil
    }

    private func present(_ image: CVImageBuffer, scaler: (Scaler, Int, Int)?) {
        guard let (s, _, _) = scaler, let pool = s.pool else { display(image); return }
        lock.lock()
        // 超分跟不上时（上一帧还没做完）这一帧不放大直接显示，绝不排队
        if inFlight >= 1 { lock.unlock(); display(image); return }
        inFlight += 1
        lock.unlock()
        let done = { [weak self] in self?.lock.lock(); self?.inFlight -= 1; self?.lock.unlock() }
        var out: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out)
        let pts = CMTime(value: CMTimeValue(monotonicNs()), timescale: 1_000_000_000)
        guard let out,
              let src = VTFrameProcessorFrame(buffer: image, presentationTimeStamp: pts),
              let dst = VTFrameProcessorFrame(buffer: out, presentationTimeStamp: pts) else {
            done(); display(image); return
        }
        let params = VTLowLatencySuperResolutionScalerParameters(sourceFrame: src, destinationFrame: dst)
        s.processor.process(parameters: params) { [weak self] _, error in
            done()
            self?.display(error == nil ? out : image)
        }
    }

    private func display(_ image: CVImageBuffer) {
        displayQueue.async { [layer] in
            var desc: CMVideoFormatDescription?
            guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: image, formatDescriptionOut: &desc) == noErr, let desc else { return }
            var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMTime(value: CMTimeValue(monotonicNs()), timescale: 1_000_000_000), decodeTimeStamp: .invalid)
            var sample: CMSampleBuffer?
            guard CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: image, formatDescription: desc, sampleTiming: &timing, sampleBufferOut: &sample) == noErr,
                  let sample else { return }
            VideoRenderer.markImmediate(sample, isKey: true)
            let r = layer.sampleBufferRenderer
            if r.status == .failed { r.flush() }
            r.enqueue(sample)
            PadTelemetry.shared.presentedFrame()
        }
    }
}
