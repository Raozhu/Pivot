import SwiftUI

/// 等待 Mac 连接时的界面。
struct IdleView: View {
    let hostName: String
    let connected: Bool
    var remoteStatus = ""

    @State private var appeared = false
    @State private var portrait = true
    @State private var drift = false

    private let flip = Timer.publish(every: 2.6, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            backdrop
            VStack(spacing: 0) {
                Spacer()
                device
                    .frame(width: 260, height: 260)
                    .opacity(appeared ? 1 : 0)
                    .scaleEffect(appeared ? 1 : 0.9)
                    .animation(.spring(response: 0.7, dampingFraction: 0.8), value: appeared)

                Text("Pivot")
                    .font(.system(size: 44, weight: .semibold, design: .rounded))
                    .tracking(1)
                    .foregroundStyle(.white)
                    .padding(.top, 28)
                    .modifier(Rise(appeared: appeared, delay: 0.12))

                Text("把这台 iPad 变成 Mac 的另一块屏幕，横竖都行")
                    .font(.system(size: 17))
                    .foregroundStyle(.white.opacity(0.55))
                    .padding(.top, 8)
                    .modifier(Rise(appeared: appeared, delay: 0.2))

                statusPill
                    .padding(.top, 34)
                    .modifier(Rise(appeared: appeared, delay: 0.3))
                Spacer()
                steps
                    .padding(.bottom, 44)
                    .modifier(Rise(appeared: appeared, delay: 0.42))
            }
            .padding(.horizontal, 32)
            remoteButton
        }
        .ignoresSafeArea()

        .onAppear {
            appeared = true
            withAnimation(.easeInOut(duration: 9).repeatForever(autoreverses: true)) { drift = true }
        }
        .onReceive(flip) { _ in
            withAnimation(.spring(response: 0.75, dampingFraction: 0.68)) { portrait.toggle() }
        }
    }

    // MARK: 背景

    private var backdrop: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.04, green: 0.05, blue: 0.09), Color(red: 0.01, green: 0.01, blue: 0.03)],
                           startPoint: .top, endPoint: .bottom)
            Circle()
                .fill(Color(red: 0.25, green: 0.42, blue: 1.0).opacity(0.28))
                .frame(width: 560, height: 560)
                .blur(radius: 140)
                .offset(x: drift ? -120 : 140, y: drift ? -220 : -120)
            Circle()
                .fill(Color(red: 0.62, green: 0.3, blue: 1.0).opacity(0.2))
                .frame(width: 460, height: 460)
                .blur(radius: 130)
                .offset(x: drift ? 170 : -110, y: drift ? 220 : 300)
        }
    }

    // MARK: 设备示意

    private var device: some View {
        ZStack {
            // 竖放与横放两种姿态之间来回转
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(LinearGradient(colors: [Color.white.opacity(0.14), Color.white.opacity(0.04)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(LinearGradient(colors: [Color.white.opacity(0.9), Color.white.opacity(0.25)],
                                                     startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 2.5)
                )
                .overlay(miniDesktop.padding(12))
                .frame(width: portrait ? 150 : 216, height: portrait ? 216 : 150)
                .shadow(color: Color(red: 0.3, green: 0.5, blue: 1).opacity(0.45), radius: 40, y: 12)
        }
    }

    /// 屏幕里的迷你桌面：菜单栏、一个窗口、一排程序坞，随姿态重新排布
    private var miniDesktop: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack(alignment: .topLeading) {
                Capsule().fill(Color.white.opacity(0.35)).frame(width: w, height: 5)
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.white.opacity(0.2))
                    .frame(width: w * (portrait ? 0.86 : 0.58), height: h * (portrait ? 0.52 : 0.56))
                    .offset(x: w * 0.07, y: 16)
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color(red: 0.4, green: 0.6, blue: 1).opacity(0.55))
                    .frame(width: w * (portrait ? 0.6 : 0.36), height: h * (portrait ? 0.24 : 0.5))
                    .offset(x: w * (portrait ? 0.3 : 0.58), y: portrait ? h * 0.5 : 26)
                HStack(spacing: 4) {
                    ForEach(0..<5, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 3, style: .continuous).fill(Color.white.opacity(0.45)).frame(width: 10, height: 10)
                    }
                }
                .padding(4)
                .background(Capsule().fill(Color.white.opacity(0.14)))
                .frame(width: w, alignment: .center)
                .offset(y: h - 20)
            }
        }
    }

    // MARK: 远程

    private var remoteButton: some View {
        VStack {
            HStack {
                Spacer()
                if !remoteStatus.isEmpty {
                    Label(remoteStatus, systemImage: "globe")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.55))
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(Capsule().fill(.ultraThinMaterial))
                }
            }
            Spacer()
        }
        .padding(.top, 28)
        .padding(.trailing, 28)
    }

    // MARK: 状态与步骤

    private var statusPill: some View {
        HStack(spacing: 10) {
            PulseDot(color: connected ? .green : Color(red: 1, green: 0.72, blue: 0.2))
            Text(connected ? (hostName.isEmpty ? "已连接，正在准备画面…" : "已连接 \(hostName)，正在准备画面…") : "正在等待 Mac…")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
                .id(connected)
                .transition(.opacity)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
        .background(Capsule().fill(.ultraThinMaterial))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
        .animation(.easeInOut(duration: 0.3), value: connected)
    }

    private var steps: some View {
        HStack(spacing: 28) {
            Step(icon: "cable.connector", text: "首次用 USB‑C 线连接，之后可无线")
            Step(icon: "menubar.arrow.up.rectangle", text: "在 Mac 上打开 Pivot")
            Step(icon: "rotate.right", text: "随意旋转 iPad")
        }
    }
}

private struct Step: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 15, weight: .medium)).foregroundStyle(.white.opacity(0.7))
            Text(text).font(.system(size: 14)).foregroundStyle(.white.opacity(0.5))
        }
    }
}

private struct PulseDot: View {
    let color: Color
    @State private var on = false

    var body: some View {
        ZStack {
            Circle().fill(color.opacity(0.5)).frame(width: 10, height: 10).scaleEffect(on ? 2.4 : 1).opacity(on ? 0 : 0.9)
            Circle().fill(color).frame(width: 10, height: 10)
        }
        .onAppear { withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) { on = true } }
    }
}

private struct Rise: ViewModifier {
    let appeared: Bool
    let delay: Double

    func body(content: Content) -> some View {
        content
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 16)
            .animation(.spring(response: 0.6, dampingFraction: 0.85).delay(delay), value: appeared)
    }
}
