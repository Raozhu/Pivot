import Foundation
import AVFoundation

/// 播放 Mac 传来的声音。只留很薄的缓冲（约 20～120 ms）：宁可偶尔断一下，也不让声音越拖越晚。
final class AudioPlayer {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let queue = DispatchQueue(label: "pivot.audio.play", qos: .userInteractive)
    private var decoder: OpusDecoder?
    private var running = false
    private var attached = false
    private var lastSeq: UInt32 = 0
    /// 已排进播放器还没播完的帧数（queue 上）
    private var queuedFrames = 0
    private var observer: NSObjectProtocol?

    /// 超过这么多就丢包追上去（120 ms）
    private static let maxQueued = Int(AudioCodec.sampleRate * 0.12)
    /// 断流后重新起播时先垫一点静音（20 ms），吸收网络抖动
    private static let cushion = AVAudioFrameCount(AudioCodec.sampleRate * 0.02)

    init() {
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            // 换了输出设备（插拔耳机、连蓝牙）：引擎会停，重新启动
            self?.queue.async { self?.restartEngine() }
        }
    }

    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    func start() {
        queue.async { [self] in
            guard !running else { return }
            let session = AVAudioSession.sharedInstance()
            do {
                try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
                try session.setPreferredIOBufferDuration(0.005)
                try session.setActive(true)
            } catch {
                print("声音：音频会话设置失败 \(error)")
            }
            if !attached {
                engine.attach(node)
                engine.connect(node, to: engine.mainMixerNode, format: AudioCodec.pcmFormat)
                attached = true
            }
            decoder = OpusDecoder()
            lastSeq = 0
            queuedFrames = 0
            running = true
            restartEngine()
        }
    }

    func stop() {
        queue.async { [self] in
            guard running else { return }
            running = false
            node.stop()
            engine.stop()
            queuedFrames = 0
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    private func restartEngine() {
        guard running, !engine.isRunning else { return }
        do {
            try engine.start()
            queuedFrames = 0
        } catch {
            print("声音：播放引擎启动失败 \(error)")
        }
    }

    /// 任意线程
    func play(_ payload: Data) {
        queue.async { [self] in
            guard running, engine.isRunning, let (seq, opus) = AudioCodec.parse(payload) else { return }
            // 重复或过时的包不播
            if lastSeq != 0, Int32(bitPattern: seq &- lastSeq) <= 0 { return }
            lastSeq = seq
            guard let pcm = decoder?.decode(opus) else { return }
            if queuedFrames > Self.maxQueued { return }
            if queuedFrames == 0, let silence = AVAudioPCMBuffer(pcmFormat: AudioCodec.pcmFormat, frameCapacity: Self.cushion) {
                silence.frameLength = Self.cushion   // 新分配的缓冲是全零，即静音
                schedule(silence)
            }
            schedule(pcm)
            if !node.isPlaying { node.play() }
        }
    }

    private func schedule(_ buffer: AVAudioPCMBuffer) {
        let n = Int(buffer.frameLength)
        queuedFrames += n
        node.scheduleBuffer(buffer, completionCallbackType: .dataConsumed) { [weak self] _ in
            self?.queue.async { self?.queuedFrames = max(0, (self?.queuedFrames ?? 0) - n) }
        }
    }
}
