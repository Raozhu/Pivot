import Foundation
import AVFoundation

/// 声音编解码：Opus，48 kHz 立体声，每包 10 ms（480 帧）。系统自带编解码器，不引入第三方库。
enum AudioCodec {
    static let sampleRate = 48_000.0
    static let channels: AVAudioChannelCount = 2
    static let frameSize: AVAudioFrameCount = 480
    static let bitRate = 96_000

    /// 非交错 float32 PCM
    static let pcmFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: channels, interleaved: false)!

    static let opusFormat: AVAudioFormat = {
        var desc = AudioStreamBasicDescription(mSampleRate: sampleRate, mFormatID: kAudioFormatOpus, mFormatFlags: 0,
                                               mBytesPerPacket: 0, mFramesPerPacket: UInt32(frameSize), mBytesPerFrame: 0,
                                               mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 0, mReserved: 0)
        return AVAudioFormat(streamDescription: &desc)!
    }()

    /// 负载：u32 序号 + Opus 包
    static func packet(seq: UInt32, opus: Data) -> Data {
        var d = Data(capacity: 4 + opus.count)
        d.appendLE(seq)
        d.append(opus)
        return d
    }

    static func parse(_ payload: Data) -> (seq: UInt32, opus: Data)? {
        guard payload.count > 4 else { return nil }
        return (payload.readLE(UInt32.self, at: 0), payload.subdata(in: (payload.startIndex + 4)..<payload.endIndex))
    }
}

final class OpusEncoder {
    private let converter: AVAudioConverter
    private let maxPacket: Int

    init?() {
        guard let c = AVAudioConverter(from: AudioCodec.pcmFormat, to: AudioCodec.opusFormat) else { return nil }
        c.bitRate = AudioCodec.bitRate
        converter = c
        maxPacket = max(c.maximumOutputPacketSize, 1500)
    }

    /// 输入正好 480 帧
    func encode(_ pcm: AVAudioPCMBuffer) -> Data? {
        let out = AVAudioCompressedBuffer(format: AudioCodec.opusFormat, packetCapacity: 1, maximumPacketSize: maxPacket)
        var given = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, s in
            if given { s.pointee = .noDataNow; return nil }
            given = true
            s.pointee = .haveData
            return pcm
        }
        guard status != .error, out.packetCount > 0, out.byteLength > 0 else { return nil }
        return Data(bytes: out.data, count: Int(out.byteLength))
    }
}

final class OpusDecoder {
    private let converter: AVAudioConverter

    init?() {
        guard let c = AVAudioConverter(from: AudioCodec.opusFormat, to: AudioCodec.pcmFormat) else { return nil }
        converter = c
    }

    func decode(_ opus: Data) -> AVAudioPCMBuffer? {
        let input = AVAudioCompressedBuffer(format: AudioCodec.opusFormat, packetCapacity: 1, maximumPacketSize: max(opus.count, 1))
        opus.withUnsafeBytes { input.data.copyMemory(from: $0.baseAddress!, byteCount: opus.count) }
        input.byteLength = UInt32(opus.count)
        input.packetCount = 1
        input.packetDescriptions?.pointee = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(opus.count))
        guard let out = AVAudioPCMBuffer(pcmFormat: AudioCodec.pcmFormat, frameCapacity: AudioCodec.frameSize * 2) else { return nil }
        var given = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, s in
            if given { s.pointee = .noDataNow; return nil }
            given = true
            s.pointee = .haveData
            return input
        }
        guard status != .error, out.frameLength > 0 else { return nil }
        return out
    }
}
