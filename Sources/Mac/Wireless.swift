import Foundation
import Network

/// 在本地网络（含点对点直连）上广播自己的 iPad
struct WirelessPeer: Equatable {
    let deviceID: String
    let name: String
    let endpoint: NWEndpoint
}

/// 浏览 Bonjour 服务，持续报告当前可见的 iPad。回调在内部队列上触发。
final class WirelessBrowser {
    private var browser: NWBrowser?
    private let queue = DispatchQueue(label: "pivot.browse")
    var onChange: (([WirelessPeer]) -> Void)?

    func start() {
        queue.async { [self] in
            guard browser == nil else { return }
            let params = NWParameters()
            params.includePeerToPeer = false  // 只在同一局域网里找，不唤醒 AWDL
            let browser = NWBrowser(for: .bonjourWithTXTRecord(type: Wire.bonjourType, domain: nil), using: params)
            browser.browseResultsChangedHandler = { [weak self] results, _ in
                var peers: [WirelessPeer] = []
                for result in results {
                    guard case .service(let name, _, _, _) = result.endpoint,
                          case .bonjour(let txt) = result.metadata,
                          let id = txt[Wire.txtDeviceID] else { continue }
                    peers.append(WirelessPeer(deviceID: id, name: name, endpoint: result.endpoint))
                }
                self?.onChange?(peers)
            }
            browser.stateUpdateHandler = { [weak self] state in
                guard let self, case .failed = state else { return }
                self.browser?.cancel()
                self.browser = nil
                self.queue.asyncAfter(deadline: .now() + 2) { self.start() }
            }
            browser.start(queue: queue)
            self.browser = browser
        }
    }
}

/// 已配对设备的密钥。存在本应用的偏好设置里。
enum PairingStore {
    private static let defaultsKey = "pairedDevices"

    private static var all: [String: [String: String]] {
        get { UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: [String: String]] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: defaultsKey) }
    }

    static func key(for deviceID: String) -> Data? {
        all[deviceID]?["key"].flatMap { Data(base64Encoded: $0) }
    }

    /// 返回是否是新配对或密钥有变化
    @discardableResult
    static func save(deviceID: String, key: Data, name: String) -> Bool {
        let encoded = key.base64EncodedString()
        var devices = all
        let changed = devices[deviceID]?["key"] != encoded
        // 远程监听端口：沿用已分配的，否则取下一个空闲的
        let used = Set(devices.values.compactMap { $0["port"].flatMap(UInt16.init) })
        let port = devices[deviceID]?["port"] ?? String((0..<200).map { Wire.remotePortBase + $0 }.first { !used.contains($0) } ?? Wire.remotePortBase)
        devices[deviceID] = ["key": encoded, "name": name, "port": port]
        all = devices
        return changed
    }

    static func remotePort(for deviceID: String) -> UInt16? { all[deviceID]?["port"].flatMap(UInt16.init) }

    /// 配过远程端口的设备（旧版本配对的设备要重新插线一次才有）
    static func remoteDevices() -> [String: (key: Data, port: UInt16)] {
        var result: [String: (key: Data, port: UInt16)] = [:]
        for (id, entry) in all {
            if let k = entry["key"].flatMap({ Data(base64Encoded: $0) }), let p = entry["port"].flatMap(UInt16.init) { result[id] = (k, p) }
        }
        return result
    }

    static func name(for deviceID: String) -> String? { all[deviceID]?["name"] }

    static var pairedCount: Int { all.count }

    static func forgetAll() { all = [:] }
}
