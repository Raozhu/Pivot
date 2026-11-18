// 无线链路的本机回环自测：同一台 Mac 上起监听和浏览，验证
// 1) Bonjour 广播与带 TXT 的发现  2) 密钥一致时 TLS‑PSK 握手成功并能收发  3) 密钥不一致时被拒
// 用法：scripts/wireless-selftest.sh
import Foundation
import Network

let queue = DispatchQueue(label: "selftest")
let key = Pairing.generateKey()
let wrongKey = Pairing.generateKey()
let deviceID = "selftest-\(UInt32.random(in: 0...UInt32.max))"
var failures = 0

func report(_ ok: Bool, _ what: String) {
    print(ok ? "✓ \(what)" : "✗ \(what)")
    if !ok { failures += 1 }
}

// 监听端（扮演 iPad）
let listener = try! NWListener(using: Pairing.parameters(key: key))
var txt = NWTXTRecord()
txt[Wire.txtDeviceID] = deviceID
listener.service = NWListener.Service(name: "Pivot 自测", type: Wire.bonjourType, txtRecord: txt)
listener.newConnectionHandler = { connection in
    connection.stateUpdateHandler = { state in
        if case .ready = state {
            // 回显收到的内容
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64) { data, _, _, _ in
                if let data { connection.send(content: data, completion: .contentProcessed { _ in }) }
            }
        }
    }
    connection.start(queue: queue)
}
listener.start(queue: queue)

// 浏览端（扮演 Mac）
let done = DispatchSemaphore(value: 0)
var found: NWEndpoint?
let browser = NWBrowser(for: .bonjourWithTXTRecord(type: Wire.bonjourType, domain: nil), using: {
    let p = NWParameters()
    p.includePeerToPeer = true
    return p
}())
browser.browseResultsChangedHandler = { results, _ in
    for result in results {
        if case .bonjour(let record) = result.metadata, record[Wire.txtDeviceID] == deviceID, found == nil {
            found = result.endpoint
            done.signal()
        }
    }
}
browser.start(queue: queue)
let discovered = done.wait(timeout: .now() + 8) == .success
report(discovered, "Bonjour 发现到带设备标识的服务")
guard let endpoint = found else { exit(1) }

func attempt(key: Data, label: String, expectSuccess: Bool) {
    let sem = DispatchSemaphore(value: 0)
    var success = false
    let connection = NWConnection(to: endpoint, using: Pairing.parameters(key: key))
    connection.stateUpdateHandler = { state in
        switch state {
        case .ready:
            let message = Data("ping-\(label)".utf8)
            connection.send(content: message, completion: .contentProcessed { _ in })
            connection.receive(minimumIncompleteLength: message.count, maximumLength: 64) { data, _, _, _ in
                success = data == message
                sem.signal()
            }
        case .failed, .waiting:
            sem.signal()
        default:
            break
        }
    }
    connection.start(queue: queue)
    _ = sem.wait(timeout: .now() + 6)
    connection.cancel()
    report(success == expectSuccess, expectSuccess ? "密钥一致：握手成功并完成收发" : "密钥不一致：连接被拒")
}

// 先错后对再错：既排除「会话缓存让错误密钥蒙混过关」，也确认成功连接之后错误密钥仍被拒
attempt(key: wrongKey, label: "bad-first", expectSuccess: false)
attempt(key: key, label: "good", expectSuccess: true)
attempt(key: wrongKey, label: "bad-after", expectSuccess: false)
print(failures == 0 ? "全部通过" : "有 \(failures) 项失败")
exit(failures == 0 ? 0 : 1)
