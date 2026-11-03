import SwiftUI
import UIKit

// MARK: - 科幻主题色板

private extension Color {
    static let hudBgTop = Color(red: 0.045, green: 0.075, blue: 0.14)
    static let hudBgBottom = Color(red: 0.01, green: 0.02, blue: 0.05)
    static let neonOrange = Color(red: 1.0, green: 0.47, blue: 0.10)
    static let neonCyan = Color(red: 0.25, green: 0.95, blue: 1.0)
    static let hudLine = Color.white.opacity(0.14)
    static let hudPanel = Color.white.opacity(0.055)
    static let hudText = Color.white.opacity(0.88)
    static let hudDim = Color.white.opacity(0.45)
}

// MARK: - 主界面

struct ContentView: View {
    @ObservedObject var audio: AudioEngine
    @State private var webhookDraft = ""
    @State private var showCodeAlert = false
    @State private var codeDraft = ""
    @State private var pulse = false

    var body: some View {
        ZStack {
            // 深空背景 + 霓虹光晕
            LinearGradient(colors: [.hudBgTop, .hudBgBottom],
                           startPoint: .top, endPoint: .bottom)
            Circle()
                .fill(.neonOrange.opacity(0.10))
                .frame(width: 460, height: 460)
                .blur(radius: 90)
                .offset(x: 180, y: -320)
            Circle()
                .fill(.neonCyan.opacity(0.09))
                .frame(width: 420, height: 420)
                .blur(radius: 90)
                .offset(x: -200, y: 360)
            mainContent
        }
        .preferredColorScheme(.dark)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            webhookDraft = Feishu.webhook
            PiPBubble.shared.onLog = { audio.logPublic($0) }
            PiPBubble.shared.attach(audio: audio)
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }

    private var mainContent: some View {
        VStack(spacing: 18) {
            HStack(alignment: .top) {
                header
                Spacer()
                pipLaunchButton
            }
            statusRow
            LevelMeter(db: audio.levelDB)
            dictationBar
            metrics
            pipRow
            actionButton
            webhookBar
            identityBar
            asrBar
            logPanel
        }
        .padding(.horizontal, 48)
        .padding(.vertical, 26)
    }

    private var pipLaunchButton: some View {
        Button {
            PiPBubble.shared.startPresentation()
        } label: {
            Label("悬浮球", systemImage: "record.circle")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.neonCyan)
        }
        .buttonStyle(HudButtonStyle(prominent: false))
    }

    // MARK: - 区块

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("BAVO")
                .font(.system(size: 42, weight: .black, design: .monospaced))
                .foregroundStyle(.neonOrange)
                .shadow(color: .neonOrange.opacity(0.55), radius: 10)
            Text("VOICE PROBE · 16 kHz · 512 SAMPLES · WAKE \"\(Config.wakeWord)\"")
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(.hudDim)
        }
    }

    private var statusRow: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .stroke(statusColor.opacity(0.5), lineWidth: 2)
                    .frame(width: 24, height: 24)
                Circle()
                    .fill(statusColor)
                    .frame(width: 10, height: 10)
                    .shadow(color: statusColor, radius: pulse ? 7 : 2)
                    .opacity(audio.isRunning || audio.isWakeupActive ? (pulse ? 1.0 : 0.55) : 0.4)
            }
            Text(audio.stateText.uppercased())
                .font(.system(size: 17, weight: .semibold, design: .monospaced))
                .foregroundStyle(.hudText)
            Spacer()
        }
    }

    private var statusColor: Color {
        if audio.isWakeupActive { return .green }
        return audio.isRunning ? .neonOrange : Color(uiColor: .systemGray3)
    }

    private var metrics: some View {
        HStack(spacing: 14) {
            metric(title: "LEVEL", value: String(format: "%.1f dB", audio.levelDB))
            metric(title: "FRAMES", value: "\(audio.frameCount)")
            metric(title: "WAKE", value: "\(audio.wakeupCount)×")
            metric(title: "DUR",
                   value: String(format: "%.1fs",
                                 Double(audio.frameCount * Config.frameSize) / Config.sampleRate))
        }
    }

    private func metric(title: String, value: String) -> some View {
        VStack(spacing: 5) {
            Text(title)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.neonCyan.opacity(0.75))
                .tracking(1.5)
            Text(value)
                .font(.system(size: 19, weight: .bold, design: .monospaced))
                .foregroundStyle(.hudText)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(.hudPanel)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(.hudLine, lineWidth: 0.8)
        )
    }

    private var actionButton: some View {
        Button {
            if audio.isRunning { audio.stop() } else { audio.start() }
        } label: {
            Text(audio.isRunning ? "■  停止采集" : "●  开始采集")
                .font(.system(size: 19, weight: .black, design: .monospaced))
                .foregroundStyle(audio.isRunning ? .white : .black)
                .frame(width: 280)
                .padding(.vertical, 16)
                .background(
                    Capsule().fill(
                        audio.isRunning
                            ? AnyShapeStyle(Color(uiColor: .systemGray2))
                            : AnyShapeStyle(LinearGradient(colors: [.neonOrange, .orange],
                                                           startPoint: .leading, endPoint: .trailing))
                    )
                )
                .shadow(color: audio.isRunning ? .clear : .neonOrange.opacity(0.5), radius: 12)
        }
        .buttonStyle(.plain)
    }

    /// 速记进行中：显示实时转写文本与操作提示
    @ViewBuilder
    private var dictationBar: some View {
        if audio.isDictating {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "mic.fill")
                        .foregroundStyle(.neonOrange)
                    Text("REC · 说「结束 / 发送完毕」发送")
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundStyle(.neonOrange)
                }
                Text(audio.dictationText.isEmpty ? "（原声录音中…）" : audio.dictationText)
                    .font(.body)
                    .foregroundStyle(.hudText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 10).fill(.hudPanel))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(.neonOrange.opacity(0.4), lineWidth: 0.8))
            }
        }
    }

    /// 飞书 Webhook 设置栏
    private var webhookBar: some View {
        hudBar(icon: "bell.badge") {
            TextField("飞书通知：粘贴 Webhook 地址，或 AppID,AppSecret",
                      text: $webhookDraft)
                .textFieldStyle(.plain)
                .font(.system(size: 14, design: .monospaced))
                .foregroundStyle(.hudText)
                .disableAutocorrection(true)
                .textInputAutocapitalization(.never)
                .onChange(of: webhookDraft) { Feishu.saveWebhook($0) }
            Button {
                if Feishu.webhook.isEmpty {
                    audio.logPublic("配置为空：请粘贴 Webhook 地址或 AppID,AppSecret")
                    return
                }
                audio.logPublic("正在测试飞书通知…")
                Feishu.send(text: "✅ MicProbe 测试消息：飞书通知链路已打通") { err in
                    if let err {
                        audio.logPublic("飞书测试失败：\(err)")
                    } else {
                        audio.logPublic("飞书测试成功 ✓ 请查看机器人私聊消息")
                    }
                }
            } label: {
                Text("测试")
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundStyle(.neonCyan)
            }
            .buttonStyle(HudButtonStyle(prominent: false))
        }
    }

    /// 发送身份：绑定后消息以用户本人名义发出
    private var identityBar: some View {
        hudBar(icon: Feishu.userTokenBound ? "person.fill.checkmark" : "person.crop.circle.badge.questionmark") {
            Text(Feishu.userTokenBound
                 ? "身份：我本人 ✓"
                 : "身份：机器人（建议绑定）")
                .font(.system(size: 14, design: .monospaced))
                .foregroundStyle(Feishu.userTokenBound ? .green : .hudDim)
            if Feishu.userTokenBound {
                Button {
                    Feishu.unbindUser()
                    audio.logPublic("已解绑用户身份，恢复机器人名义发送")
                } label: {
                    Text("解绑")
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .foregroundStyle(.neonCyan)
                }
                .buttonStyle(HudButtonStyle(prominent: false))
            } else {
                Button {
                    Feishu.startUserAuth { line in audio.logPublic(line) }
                } label: {
                    Text("绑定我的身份")
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .foregroundStyle(.black)
                }
                .buttonStyle(HudButtonStyle(prominent: true))
                Button {
                    codeDraft = ""
                    showCodeAlert = true
                } label: {
                    Text("粘贴授权码")
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .foregroundStyle(.neonCyan)
                }
                .buttonStyle(HudButtonStyle(prominent: false))
                .alert("粘贴授权码", isPresented: $showCodeAlert) {
                    TextField("浏览器地址栏里的 code=…", text: $codeDraft)
                    Button("绑定") {
                        Feishu.bindWithCode(codeDraft) { line in audio.logPublic(line) }
                    }
                    Button("取消", role: .cancel) {}
                } message: {
                    Text("授权页登录后若浏览器报「无法连接」，从地址栏复制 code= 后面那串字符粘到这里")
                }
            }
        }
    }

    /// 局域网转写服务自检
    private var asrBar: some View {
        hudBar(icon: "dot.radiowaves.left.and.right") {
            Text("ASR \(RemoteASR.serverHost)")
                .font(.system(size: 14, design: .monospaced))
                .foregroundStyle(.hudDim)
            Button {
                audio.checkASR()
            } label: {
                Text("网络自检")
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundStyle(.neonCyan)
            }
            .buttonStyle(HudButtonStyle(prominent: false))
        }
    }

    private var logPanel: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 3) {
                ForEach(audio.logs.indices, id: \.self) { i in
                    Text(audio.logs[i])
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.green.opacity(0.75))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(14)
        }
        .frame(maxWidth: 680, maxHeight: 170)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.black.opacity(0.5)))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(.neonCyan.opacity(0.25), lineWidth: 0.8)
        )
    }

    // MARK: - 通用 HUD 行容器

    private func hudBar<Content: View>(icon: String,
                                       @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(.neonCyan.opacity(0.8))
            content()
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: 680)
        .background(RoundedRectangle(cornerRadius: 10).fill(.hudPanel))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.hudLine, lineWidth: 0.8))
    }

    /// 画中画悬浮窗预览与说明
    private var pipRow: some View {
        HStack(spacing: 14) {
            PiPHostView()
                .frame(width: 144, height: 81)
                .background(Color.black)
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(.neonCyan.opacity(0.35), lineWidth: 0.8)
                )
            VStack(alignment: .leading, spacing: 4) {
                Text("桌面悬浮窗")
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundStyle(.hudText)
                Text("点右上「悬浮球」，App 缩成画中画小窗浮在桌面/其他 App 上方；点小窗的展开按钮返回。")
                    .font(.caption)
                    .foregroundStyle(.hudDim)
            }
            Spacer()
        }
        .frame(maxWidth: 680)
    }
}

// MARK: - HUD 按钮样式

struct HudButtonStyle: ButtonStyle {
    let prominent: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                Capsule().fill(prominent ? AnyShapeStyle(.neonOrange) : AnyShapeStyle(Color.white.opacity(0.08)))
            )
            .overlay(
                Capsule().stroke(prominent ? .clear : .neonCyan.opacity(0.5), lineWidth: 1)
            )
            .opacity(configuration.isPressed ? 0.6 : 1.0)
    }
}

/// 画中画视频层的宿主视图（内嵌预览）
struct PiPHostView: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView { PiPBubble.shared.containerView() }
    func updateUIView(_ uiView: UIView, context: Context) {}
}

/// 电平条：-60 dBFS ~ 0 dBFS 映射到 0 ~ 1 宽度（霓虹渐变光条）
struct LevelMeter: View {
    let db: Float

    private var normalized: CGFloat {
        let clamped = max(-60, min(0, Double(db)))
        return CGFloat((clamped + 60) / 60)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.white.opacity(0.08))
                RoundedRectangle(cornerRadius: 6)
                    .fill(LinearGradient(colors: [.neonCyan, .green, .neonOrange, .red],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(0, geo.size.width * normalized))
                    .shadow(color: normalized > 0.85 ? .red : .neonCyan.opacity(0.6), radius: 6)
                    .animation(.linear(duration: 0.06), value: normalized)
            }
        }
        .frame(height: 18)
        .frame(maxWidth: 680)
    }
}
