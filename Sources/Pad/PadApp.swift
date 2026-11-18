import SwiftUI
import UIKit

@main
struct PivotPadApp: App {
    @StateObject private var model = PadModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .preferredColorScheme(.dark)
                .persistentSystemOverlays(.hidden)
                .statusBarHidden()
                .onAppear { model.start() }
                .onChange(of: scenePhase) { _, phase in
                    // 退到后台时系统会冻结网络，主动断开让 Mac 立刻收起显示器
                    if phase == .active { model.start() } else if phase == .background { model.stop() }
                }
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var model: PadModel

    var body: some View {
        ZStack {
            StreamContainer(model: model)
                .ignoresSafeArea()
            if !model.showingStream {
                IdleView(hostName: model.hostName, connected: model.connected, remoteStatus: model.remoteStatus)
                    .transition(.asymmetric(insertion: .opacity, removal: .opacity.combined(with: .scale(scale: 1.08))))
            }
            if model.showingStream && model.connected {
                ToolbarView()
                    // 屏幕键盘弹出时工具条原地不动
                    .ignoresSafeArea(.keyboard)
                    .transition(.opacity)
            }
            if model.reconnecting {
                VStack {
                    HStack(spacing: 10) {
                        ProgressView().tint(.white)
                        Text("正在重新连接…").font(.system(size: 15, weight: .medium)).foregroundStyle(.white)
                    }
                    .padding(.horizontal, 18).padding(.vertical, 11)
                    .background(Capsule().fill(.ultraThinMaterial))
                    .padding(.top, 28)
                    Spacer()
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: model.reconnecting)
        .background(Color.black)
        .animation(.easeInOut(duration: 0.45), value: model.showingStream)
        // 屏幕键盘不挤压整个界面（画面和工具条都不跟着动）
        .ignoresSafeArea(.keyboard)
    }
}

struct StreamContainer: UIViewControllerRepresentable {
    let model: PadModel

    func makeUIViewController(context: Context) -> StreamViewController {
        let vc = StreamViewController()
        vc.model = model
        model.attach(vc)
        return vc
    }

    func updateUIViewController(_ vc: StreamViewController, context: Context) {}
}
