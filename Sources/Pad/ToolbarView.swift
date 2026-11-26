import SwiftUI

/// 悬浮在画面上的小工具条：修饰键和屏幕键盘。
/// 平时只是屏幕边上一个半透明的小圆点，点一下展开；可以沿边缘上下拖动，也可以拖到另一侧。
struct ToolbarView: View {
    @EnvironmentObject private var model: PadModel
    @AppStorage("toolbarTrailing") private var trailing = true
    @AppStorage("toolbarY") private var yFraction = 0.5
    @State private var expanded = false
    @State private var dragOffset = CGSize.zero
    @State private var dragging = false

    private struct Modifier: Identifiable {
        let id: UInt16      // HID 用途码
        let symbol: String
    }

    private let modifiers = [
        Modifier(id: 0xE3, symbol: "command"),
        Modifier(id: 0xE2, symbol: "option"),
        Modifier(id: 0xE0, symbol: "control"),
        Modifier(id: 0xE1, symbol: "shift"),
    ]

    var body: some View {
        GeometryReader { geo in
            let margin: CGFloat = 14
            let x = trailing ? geo.size.width - margin - 24 : margin + 24
            let minY: CGFloat = 60, maxY = max(60, geo.size.height - 60)
            let y = min(maxY, max(minY, geo.size.height * yFraction))

            // 手势必须挂在按钮本身上、再做定位。反过来的话，定位后的视图铺满全屏，
            // 拖动手势会把整块屏幕上的滑动都抢走，画面上的触控就只剩点按能用。
            content
                .gesture(
                    DragGesture(minimumDistance: 8, coordinateSpace: .global)
                        .onChanged { value in
                            dragging = true
                            dragOffset = value.translation
                        }
                        .onEnded { value in
                            let endX = x + value.translation.width
                            let endY = min(maxY, max(minY, y + value.translation.height))
                            withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) {
                                trailing = endX > geo.size.width / 2
                                yFraction = endY / max(1, geo.size.height)
                                dragOffset = .zero
                            }
                            dragging = false
                        }
                )
                .position(x: x + dragOffset.width, y: y + dragOffset.height)
        }
        .allowsHitTesting(true)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: expanded)
    }

    static func icon(_ m: DisplayMode) -> String {
        switch m {
        case .extend: return "rectangle.split.2x1"
        case .mirror: return "rectangle.on.rectangle"
        case .solo: return "ipad"
        }
    }

    @ViewBuilder
    private var content: some View {
        if expanded {
            VStack(spacing: 6) {
                ForEach(modifiers) { modifier in
                    let on = model.latchedModifiers.contains(modifier.id)
                    Button { model.toggleModifier(modifier.id) } label: {
                        Image(systemName: modifier.symbol)
                            .font(.system(size: 17, weight: .semibold))
                            .frame(width: 40, height: 40)
                            .foregroundStyle(on ? Color.black : Color.white)
                            .background(Circle().fill(on ? Color.white : Color.white.opacity(0.12)))
                            .scaleEffect(on ? 1.06 : 1)
                    }
                    .buttonStyle(.plain)
                    .animation(.spring(response: 0.25, dampingFraction: 0.6), value: on)
                }
                Divider().frame(width: 26).overlay(Color.white.opacity(0.25))
                // 显示模式：扩展屏 / 镜像 / 仅 iPad
                Menu {
                    ForEach(DisplayMode.allCases, id: \.self) { m in
                        Button { model.setDisplayMode(m) } label: {
                            Label(m.label, systemImage: m == model.displayMode ? "checkmark" : Self.icon(m))
                        }
                    }
                } label: {
                    Image(systemName: Self.icon(model.displayMode))
                        .font(.system(size: 15, weight: .medium))
                        .frame(width: 40, height: 40)
                        .foregroundStyle(.white)
                        .background(Circle().fill(Color.white.opacity(model.displayMode == .extend ? 0.12 : 0.3)))
                }
                .accessibilityLabel("显示模式：\(model.displayMode.label)")
                // 跟手选项：出问题时可以单独关掉
                Menu {
                    Toggle(isOn: $model.touchPredict) { Label("触控预测", systemImage: "hand.point.up.left") }
                    Toggle(isOn: $model.scrollAhead) { Label("滚动先行", systemImage: "arrow.up.and.down.text.horizontal") }
                    if model.superResolutionSupported {
                        Toggle(isOn: $model.superResolution) { Label("超分辨率", systemImage: "sparkles") }
                    }
                    Picker(selection: $model.quality) {
                        ForEach(StreamQuality.allCases, id: \.self) { Text($0.label).tag($0) }
                    } label: { Label("清晰度", systemImage: "photo") }
                    .pickerStyle(.menu)
                } label: {
                    Image(systemName: "speedometer")
                        .font(.system(size: 15, weight: .medium))
                        .frame(width: 40, height: 40)
                        .foregroundStyle(.white)
                        .background(Circle().fill(Color.white.opacity(0.12)))
                }
                .accessibilityLabel("画质与跟手")
                Button { model.setKeyboardVisible(!model.keyboardVisible) } label: {
                    Image(systemName: model.keyboardVisible ? "keyboard.chevron.compact.down" : "keyboard")
                        .font(.system(size: 16, weight: .medium))
                        .frame(width: 40, height: 40)
                        .foregroundStyle(.white)
                        .background(Circle().fill(Color.white.opacity(model.keyboardVisible ? 0.3 : 0.12)))
                }
                .buttonStyle(.plain)
                // 声音一键开关
                Button { model.toggleAudio() } label: {
                    Image(systemName: model.audioEnabled ? "speaker.wave.2.fill" : "speaker.slash")
                        .font(.system(size: 15, weight: .medium))
                        .frame(width: 40, height: 40)
                        .foregroundStyle(.white)
                        .background(Circle().fill(Color.white.opacity(model.audioEnabled ? 0.3 : 0.12)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(model.audioEnabled ? "关闭声音" : "打开声音")
                Button { expanded = false } label: {
                    Image(systemName: "chevron.compact.down")
                        .font(.system(size: 18, weight: .semibold))
                        .frame(width: 40, height: 26)
                        .foregroundStyle(.white.opacity(0.7))
                }
                .buttonStyle(.plain)
            }
            .padding(6)
            .background(Capsule().fill(.ultraThinMaterial))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
            .environment(\.colorScheme, .dark)
            .transition(.scale(scale: 0.6).combined(with: .opacity))
        } else {
            // 收起状态：有修饰键锁定时变亮提醒
            let active = !model.latchedModifiers.isEmpty
            Button { expanded = true } label: {
                Image(systemName: "command")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 38, height: 38)
                    .foregroundStyle(active ? Color.black : Color.white)
                    .background(Circle().fill(active ? AnyShapeStyle(Color.white) : AnyShapeStyle(.ultraThinMaterial)))
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.18), lineWidth: 1))
                    .opacity(active || dragging ? 1 : 0.45)
                    .environment(\.colorScheme, .dark)
            }
            .buttonStyle(.plain)
            .transition(.scale(scale: 0.6).combined(with: .opacity))
        }
    }
}
