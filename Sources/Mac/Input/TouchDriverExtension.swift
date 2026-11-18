import Foundation
import SystemExtensions

/// 启用 Pivot 自带的触摸屏驱动（`Contents/Library/SystemExtensions` 里的 dext）。
/// 首次启用要在「系统设置 › 通用 › 登录项与扩展 › 驱动程序扩展」里同意一次。
/// 启用成功后 `active` 为 true，之后新建的触控后端才用原生触摸屏。
final class TouchDriverExtension: NSObject, OSSystemExtensionRequestDelegate {
    static let shared = TouchDriverExtension()
    static let identifier = "com.example.pivot.host.touchdriver"
    /// 驱动刚启用：已经建好的触控后端可以换成原生触摸屏
    static let activated = Notification.Name("PivotTouchDriverActivated")

    private(set) var active = false
    private(set) var status = "未启用"
    var onChange: (() -> Void)?

    var isBundled: Bool {
        FileManager.default.fileExists(atPath: Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/SystemExtensions/\(Self.identifier).dext").path)
    }

    func activate() {
        guard isBundled else { set("这一版没有打包驱动"); return }
        set("正在启用驱动…")
        let request = OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: Self.identifier, queue: .main)
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    private func set(_ s: String, active: Bool = false) {
        status = s
        self.active = active
        Log.info("触摸屏驱动：\(s)")
        onChange?()
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        set("等待同意：系统设置 › 通用 › 登录项与扩展 › 驱动程序扩展，打开 Pivot")
    }

    func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        switch result {
        case .completed:
            set("已启用", active: true)
            NotificationCenter.default.post(name: Self.activated, object: nil)
        case .willCompleteAfterReboot: set("重启后生效")
        @unknown default: set("结果 \(result.rawValue)")
        }
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        set("启用失败：\(error.localizedDescription)")
    }

    func request(_ request: OSSystemExtensionRequest, actionForReplacingExtension existing: OSSystemExtensionProperties,
                 withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction { .replace }
}
