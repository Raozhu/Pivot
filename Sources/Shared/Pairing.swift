import Foundation
import Network
import Security

/// 无线连接的加密与认证：TLS 预共享密钥。
/// 密钥只通过 USB 线交换一次，所以能连上无线的一定是插线配对过的那两台设备。
enum Pairing {
    static func generateKey() -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes)
    }

    /// 无线用的连接参数：TCP + TLS‑PSK，允许点对点直连（两台设备不必在同一个 Wi‑Fi）。
    static func parameters(key: Data) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let keyData = key.withUnsafeBytes { DispatchData(bytes: $0) }
        let identity = Data("pivot".utf8).withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(tls.securityProtocolOptions, keyData as __DispatchData, identity as __DispatchData)
        sec_protocol_options_append_tls_ciphersuite(tls.securityProtocolOptions,
                                                    tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!)
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        // 关闭会话恢复：每次连接都必须用密钥完整握手，不能靠缓存的旧会话绕过校验
        sec_protocol_options_set_tls_resumption_enabled(tls.securityProtocolOptions, false)
        sec_protocol_options_set_tls_tickets_enabled(tls.securityProtocolOptions, false)

        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 2
        tcp.keepaliveInterval = 1
        tcp.keepaliveCount = 3
        tcp.connectionTimeout = 5

        let params = NWParameters(tls: tls, tcp: tcp)
        // 不走 AWDL（隔空投送用的点对点 Wi‑Fi）：它每半秒切一次信道，同一网络下的连接会周期性卡 50～70 ms
        params.includePeerToPeer = false
        params.serviceClass = .interactiveVideo
        return params
    }
}
