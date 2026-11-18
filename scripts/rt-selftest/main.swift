import Foundation
// UDP 实时通道的本机自测：加密、切片、纠错、丢包放弃、触控冗余
var failures = 0
func check(_ c: Bool, _ msg: String) { if !c { failures += 1; print("✗ \(msg)") } else { print("✓ \(msg)") } }

let key = Data((0..<32).map { UInt8($0) }), salt = Data((0..<16).map { UInt8(200 - $0) })
let host = RTCrypto(pairingKey: key, salt: salt, isHost: true), pad = RTCrypto(pairingKey: key, salt: salt, isHost: false)
let sealed = host.seal(seq: 7, Data("hello".utf8))!
check(pad.open(sealed)?.plain == Data("hello".utf8), "Mac→iPad 加解密")
check(host.open(sealed) == nil, "同方向密钥不能解自己的包")
var tampered = sealed; tampered[tampered.startIndex + 10] ^= 1
check(pad.open(tampered) == nil, "篡改后认证失败")
var win = RTReplayWindow()
check(win.accept(5) && win.accept(7) && !win.accept(7) && win.accept(6) && !win.accept(5), "防重放窗口")

func frameData(_ n: Int, _ seed: UInt8) -> Data { Data((0..<n).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ Int(seed)) }) }
var got: [RTFrameAssembler.Frame] = []
var lost = 0
let asm = RTFrameAssembler()
asm.onFrame = { got.append($0) }
asm.onLoss = { lost += $0 }

// 1. 无丢包
let fmt = Data([1, 2, 3])
let d1 = frameData(50_000, 1)
for s in RTShard.make(frame: 1, isKey: true, captureNs: 10, touchTs: 99, blob: RTShard.frameBlob(format: fmt, data: d1), parityRatio: 0.1) {
    asm.add(RTShard.decode(s.encode().dropFirst())!)
}
check(got.count == 1 && got[0].data == d1 && got[0].format == fmt && got[0].touchTs == 99 && got[0].isKey, "整帧拼回（含参数集）")

// 2. 每组丢一片，靠纠错补回
let d2 = frameData(30_000, 2)
var shards = RTShard.make(frame: 2, isKey: false, captureNs: 20, touchTs: 0, blob: RTShard.frameBlob(format: nil, data: d2), parityRatio: 0.15)
let parity = Int(shards[0].parityCount)
let drop = Set((0..<parity).map { $0 })  // 连续丢 parity 片（各在不同组）
for (i, s) in shards.enumerated() where !drop.contains(i) { asm.add(RTShard.decode(s.encode().dropFirst())!) }
check(got.count == 2 && got[1].data == d2, "连续丢 \(parity) 片，纠错补回")

// 3. 丢太多，补不回：下一帧到达时放弃
shards = RTShard.make(frame: 3, isKey: false, captureNs: 30, touchTs: 0, blob: RTShard.frameBlob(format: nil, data: frameData(30_000, 3)), parityRatio: 0.1)
for s in shards.dropFirst(5) { asm.add(RTShard.decode(s.encode().dropFirst())!) }
let d4 = frameData(2_000, 4)
for s in RTShard.make(frame: 4, isKey: false, captureNs: 40, touchTs: 0, blob: RTShard.frameBlob(format: nil, data: d4), parityRatio: 0.1) {
    asm.add(RTShard.decode(s.encode().dropFirst())!)
}
check(got.count == 3 && got[2].index == 4 && got[2].data == d4 && lost == 1, "补不回的帧被放弃，新帧照常交付（丢 \(lost) 帧）")

// 4. 迟到的旧分片被忽略
for s in shards.prefix(5) { asm.add(RTShard.decode(s.encode().dropFirst())!) }
check(got.count == 3, "旧帧迟到的分片不再交付")

// 5. 超时放弃
let s5 = RTShard.make(frame: 5, isKey: false, captureNs: 50, touchTs: 0, blob: RTShard.frameBlob(format: nil, data: frameData(10_000, 5)), parityRatio: 0.1)
asm.add(RTShard.decode(s5[0].encode().dropFirst())!)
asm.expire(now: monotonicNs() + 200_000_000)
check(lost == 2, "超时的半成品被放弃")

// 6. 触控冗余编解码
let items: [(seq: UInt32, payload: Data)] = [(1, Data([9])), (2, Data([8, 8])), (3, Data())]
let enc = RTTouch.encode(items)
let dec = RTTouch.decode(enc.dropFirst())
check(dec.count == 3 && dec[1].seq == 2 && dec[1].payload == Data([8, 8]), "触控冗余编解码")

// 7. UDP 回环 + 加密，模拟 10% 随机丢包，统计交付率
let server = RTSocket(listenPort: 47199)!, client = RTSocket(host: "127.0.0.1", port: 47199)!
var recvFrames = 0, recvLost = 0
let asm2 = RTFrameAssembler()
asm2.onFrame = { _ in recvFrames += 1 }
asm2.onLoss = { recvLost += $0 }
let q = DispatchQueue(label: "t")
client.onPacket = { data, _ in q.sync { if let (_, plain) = pad.open(data), plain.first == RT.Kind.video.rawValue, let s = RTShard.decode(plain.dropFirst()) { asm2.add(s) } } }
var peer: sockaddr_storage?
let ready = DispatchSemaphore(value: 0)
server.onPacket = { _, from in peer = from; ready.signal() }
server.start(); client.start()
client.send(Data([0]))
_ = ready.wait(timeout: .now() + 2)
var seq: UInt64 = 0
srand48(42)
for f in 1...300 {
    for s in RTShard.make(frame: UInt32(f), isKey: f == 1, captureNs: 0, touchTs: 0, blob: RTShard.frameBlob(format: nil, data: frameData(f == 1 ? 60_000 : 8_000, UInt8(f % 250))), parityRatio: 0.2) {
        seq += 1
        if drand48() < 0.10 { continue }
        server.send(host.seal(seq: seq, s.encode())!, to: peer)
    }
    usleep(2000)
}
usleep(300_000)
q.sync {}
print("  300 帧、10% 随机丢包、20% 纠错：交付 \(recvFrames) 帧，放弃 \(recvLost) 帧")
check(recvFrames > 200, "UDP 回环在 10% 丢包下大部分帧能交付")
server.close(); client.close()
print(failures == 0 ? "全部通过" : "\(failures) 项失败")
exit(failures == 0 ? 0 : 1)
