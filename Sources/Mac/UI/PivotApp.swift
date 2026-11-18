import SwiftUI
import AppKit

@main
struct PivotApp: App {
    @StateObject private var host = HostController.shared

    init() {
        if CommandLine.arguments.contains("--gesture-selftest") {
            GestureSelfTest.run()
            exit(0)
        }
        if CommandLine.arguments.contains("--record-events") {
            // 录制模式：只旁听事件，不连 iPad（把 iPad 让给随航）
            EventRecorder.run()
            return
        }
        TouchDriverExtension.shared.activate()
        HostController.shared.start()
        if CommandLine.arguments.contains("--sidecar-portrait") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { HostController.shared.setSidecarPortrait(true) }
        }
    }

    var body: some Scene {
        MenuBarExtra {
            PanelView().environmentObject(host)
        } label: {
            Image(systemName: host.phase == .streaming ? "ipad.gen2.landscape.badge.play" : "ipad.gen2.landscape")
        }
        .menuBarExtraStyle(.window)
    }
}

struct PanelView: View {
    @EnvironmentObject private var host: HostController

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if host.sidecarAvailable || host.sidecarPortrait {
                sidecarCard
            }
            if host.sidecarPortrait {
                EmptyView()
            } else if host.phase == .streaming {
                streamCard
                modePicker
                if host.displayMode != .mirror { scalePicker }
            } else {
                guide
                modePicker
            }
            permissions
            Toggle("手指触控时隐藏鼠标指针", isOn: $host.hideCursorOnTouch).toggleStyle(.checkbox).font(.system(size: 11))
            if host.pairedCount > 0 {
                HStack(spacing: 6) {
                    Image(systemName: "wifi").font(.system(size: 10))
                    Text("已配对 \(host.pairedCount) 台 iPad，可无线连接").font(.system(size: 11))
                    Spacer()
                    Button("忘记") { host.forgetPairings() }.buttonStyle(.borderless).font(.system(size: 11))
                }
                HStack(spacing: 6) {
                    Image(systemName: "globe").font(.system(size: 10))
                    Text(host.remoteStatus).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .foregroundStyle(.secondary)
            }
            Divider().opacity(0.5)
            footer
        }
        .padding(16)
        .frame(width: 320)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: host.phase)
    }

    // MARK: 头部

    private var header: some View {
        HStack(spacing: 10) {
            DeviceGlyph(active: host.phase == .streaming, portrait: host.snapshot.height >= host.snapshot.width)
                .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text("Pivot").font(.system(size: 15, weight: .semibold))
                Text(statusText).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            StatusDot(color: statusColor, pulsing: host.phase == .waitingForApp || host.phase == .connecting)
        }
    }

    private var statusText: String {
        switch host.phase {
        case .noDevice: return host.pairedCount == 0 ? "未检测到 iPad（首次请插线配对）" : "未检测到 iPad"
        case .waitingForApp: return "等待 iPad 打开 Pivot"
        case .connecting: return "正在连接…"
        case .streaming: return host.snapshot.deviceName.isEmpty ? "已连接" : "已连接 \(host.snapshot.deviceName)"
        case .failed(let message): return message
        }
    }

    private var statusColor: Color {
        switch host.phase {
        case .noDevice: return .secondary
        case .waitingForApp, .connecting: return .orange
        case .streaming: return .green
        case .failed: return .red
        }
    }

    // MARK: 推流信息

    private var streamCard: some View {
        let s = host.snapshot
        return VStack(spacing: 10) {
            HStack {
                Text("\(s.pointsWidth) × \(s.pointsHeight)")
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Spacer()
                Text(s.height >= s.width ? "竖屏" : "横屏")
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(.quaternary))
            }
            HStack(spacing: 0) {
                Metric(value: s.latencyMs > 0 ? String(format: "%.0f", s.latencyMs) : "–", unit: "ms", label: "延迟")
                Metric(value: String(format: "%.0f", s.measuredFPS), unit: "/\(s.fps)", label: "帧率")
                Metric(value: String(format: "%.1f", s.mbps), unit: "Mb", label: "码率")
            }
            HStack(spacing: 6) {
                Image(systemName: s.transport == .wired ? "cable.connector" : s.transport == .remote ? "globe" : "wifi").font(.system(size: 10))
                Text("\(s.transport.label)\(s.realtime ? "（UDP）" : "") · \(s.injector)").font(.system(size: 11))
                Spacer()
                Text("\(s.width) × \(s.height) 像素\(s.hiDPI ? " · 2x" : "")\(s.encodePercent < 100 ? " · 流畅优先 \(s.encodePercent)%" : "")").font(.system(size: 11)).monospacedDigit()
            }
            .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.quaternary.opacity(0.5)))
        .transition(.opacity.combined(with: .scale(scale: 0.97)))
    }

    /// 扩展屏（独立的一块屏）或镜像主屏。iPad 工具条上也能切。
    private var modePicker: some View {
        HStack {
            Text("iPad 用作").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            Spacer()
            Picker("", selection: $host.displayMode) {
                ForEach(DisplayMode.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 200)
            .controlSize(.small)
        }
    }

    private var scalePicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("显示缩放").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
                Text(scaleLabel(host.scale)).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            HStack(spacing: 4) {
                ForEach(Array(VirtualDisplay.scaleSteps.enumerated()), id: \.offset) { index, step in
                    ScaleChip(step: step, index: index, selected: host.scale == step) { host.scale = step }
                }
            }
        }
    }

    private func scaleLabel(_ s: Double) -> String {
        switch s {
        case ..<1: return "更大的文字"
        case 1: return "逐像素，最清晰"
        default: return "更多空间"
        }
    }

    // MARK: 随航竖屏

    private var sidecarCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "rectangle.portrait.rotate").font(.system(size: 13))
                VStack(alignment: .leading, spacing: 1) {
                    Text("随航竖屏").font(.system(size: 12, weight: .medium))
                    Text(host.sidecarPortrait ? "竖屏画面，可直接用手指操作" : "已检测到随航。iPad 横着时开旋转锁定，再竖起来用")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("", isOn: Binding(get: { host.sidecarPortrait }, set: { host.setSidecarPortrait($0) }))
                    .toggleStyle(.switch).controlSize(.small).labelsHidden()
            }
            if host.sidecarPortrait {
                HStack {
                    Text("画面方向反了？").font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    Button("旋转 180°") { host.flipSidecar() }.controlSize(.small)
                }
            }
            if !host.sidecarStatus.isEmpty, host.sidecarStatus != "已开启" {
                Text(host.sidecarStatus).font(.system(size: 10)).foregroundStyle(.orange)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.quaternary.opacity(0.5)))
    }

    // MARK: 引导

    private var guide: some View {
        VStack(alignment: .leading, spacing: 8) {
            GuideRow(index: 1, text: host.pairedCount == 0 ? "用 USB‑C 线把 iPad 接到这台 Mac（首次配对）" : "插上 USB‑C 线，或让 iPad 在附近（无线）",
                     done: host.phase != .noDevice)
            GuideRow(index: 2, text: "在 iPad 上打开 Pivot", done: host.phase == .connecting)
            GuideRow(index: 3, text: "把 iPad 转到想要的方向，画面自动跟随", done: false)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.quaternary.opacity(0.5)))
        .transition(.opacity)
    }

    // MARK: 授权

    @ViewBuilder
    private var permissions: some View {
        if !host.screenRecordingGranted || !host.accessibilityGranted {
            VStack(spacing: 6) {
                if !host.screenRecordingGranted {
                    PermissionRow(icon: "rectangle.dashed.badge.record", title: "屏幕录制", detail: "把画面送到 iPad 需要它；授权后请重新打开 Pivot") { host.requestScreenRecording() }
                }
                if !host.accessibilityGranted {
                    PermissionRow(icon: "hand.tap", title: "辅助功能", detail: "把 iPad 上的触控变成点击和手势") { host.requestAccessibility() }
                }
            }
        }
    }

    // MARK: 底部

    private var footer: some View {
        HStack {
            Toggle("暂停连接", isOn: $host.paused).toggleStyle(.checkbox).font(.system(size: 11))
            Toggle("开机启动", isOn: $host.launchAtLogin).toggleStyle(.checkbox).font(.system(size: 11))
            Spacer()
            Button("退出") { NSApp.terminate(nil) }.buttonStyle(.borderless)
        }
        .font(.system(size: 12))
    }
}

// MARK: - 组件

private struct Metric: View {
    let value: String
    let unit: String
    let label: String

    var body: some View {
        VStack(spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text(value).font(.system(size: 17, weight: .medium, design: .rounded)).monospacedDigit().contentTransition(.numericText())
                Text(unit).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Text(label).font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct ScaleChip: View {
    let step: Double
    let index: Int
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            // 字越大代表界面元素越大
            Text("A")
                .font(.system(size: 17 - CGFloat(index) * 2, weight: .semibold, design: .rounded))
                .frame(maxWidth: .infinity, minHeight: 30)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary.opacity(hovering ? 1 : 0.6))))
                .foregroundStyle(selected ? .white : .primary)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: selected)
    }
}

private struct GuideRow: View {
    let index: Int
    let text: String
    let done: Bool

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(done ? Color.green : Color.secondary.opacity(0.25)).frame(width: 18, height: 18)
                if done {
                    Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                } else {
                    Text("\(index)").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                }
            }
            Text(text).font(.system(size: 12)).foregroundStyle(done ? .secondary : .primary)
            Spacer(minLength: 0)
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: done)
    }
}

private struct PermissionRow: View {
    let icon: String
    let title: String
    let detail: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 14)).foregroundStyle(.orange).frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text("需要「\(title)」权限").font(.system(size: 12, weight: .medium))
                Text(detail).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer()
            Button("授权", action: action).controlSize(.small)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.orange.opacity(0.1)))
    }
}

private struct StatusDot: View {
    let color: Color
    let pulsing: Bool
    @State private var on = false

    var body: some View {
        ZStack {
            Circle().fill(color.opacity(0.35)).frame(width: 16, height: 16)
                .scaleEffect(pulsing && on ? 1.25 : 0.6).opacity(pulsing && on ? 0 : 1)
            Circle().fill(color).frame(width: 8, height: 8)
        }
        .onAppear { withAnimation(.easeOut(duration: 1.2).repeatForever(autoreverses: false)) { on = true } }
    }
}

/// 一块会跟着方向转动的小平板图标
private struct DeviceGlyph: View {
    let active: Bool
    let portrait: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .strokeBorder(active ? Color.accentColor : Color.secondary, lineWidth: 2)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(active ? Color.accentColor.opacity(0.18) : .clear))
            .frame(width: 22, height: 30)
            .rotationEffect(.degrees(active && !portrait ? 90 : 0))
            .animation(.spring(response: 0.5, dampingFraction: 0.65), value: portrait)
            .animation(.easeOut(duration: 0.25), value: active)
    }
}
