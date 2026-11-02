import SwiftUI

/// 迷你悬浮球：缩到一角的可拖动胶囊，绿点=监听中，橙点闪=唤醒/速记中，灰=已停止。
/// 点按恢复完整界面。
struct FloatingBubble: View {
    @ObservedObject var audio: AudioEngine
    let onExpand: () -> Void

    @State private var offset: CGSize = .zero
    @State private var pulse = false

    private var dotColor: Color {
        if audio.isDictating || audio.isWakeupActive { return .orange }
        return audio.isRunning ? .green : Color(uiColor: .systemGray2)
    }

    private var label: String {
        if audio.isDictating { return "速记中" }
        if audio.isWakeupActive { return "已唤醒" }
        return audio.isRunning ? "监听中" : "已停止"
    }

    var body: some View {
        VStack {
            HStack(spacing: 8) {
                Circle()
                    .fill(dotColor)
                    .frame(width: 12, height: 12)
                    .scaleEffect(pulse && (audio.isDictating || audio.isWakeupActive) ? 1.5 : 1.0)
                    .animation(pulse ? .easeInOut(duration: 0.7).repeatForever(autoreverses: true) : .default,
                               value: pulse && (audio.isDictating || audio.isWakeupActive))
                Text(label)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .background(Capsule().fill(Color.black.opacity(0.55)))
            .overlay(Capsule().stroke(Color.white.opacity(0.25), lineWidth: 0.5))
        }
        .offset(offset)
        .gesture(
            DragGesture()
                .onChanged { offset = $0.translation }
                .onEnded { _ in }   // 停在哪就留在哪
        )
        .onTapGesture { onExpand() }
        .onChange(of: audio.isDictating) { _ in pulse = audio.isDictating }
        .onAppear { pulse = audio.isDictating }
    }
}
