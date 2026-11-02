import SwiftUI
import UIKit

struct ContentView: View {
    @ObservedObject var audio: AudioEngine
    @State private var webhookDraft = ""

    var body: some View {
        mainContent
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(uiColor: .systemGroupedBackground))
            .onAppear {
                webhookDraft = Feishu.webhook
                PiPBubble.shared.onLog = { audio.logPublic($0) }
                PiPBubble.shared.attach(audio: audio)
            }
    }

    private var mainContent: some View {
        VStack(spacing: 20) {
            HStack(alignment: .top) {
                header
                Spacer()
                Button {
                    PiPBubble.shared.startPresentation()
                } label: {
                    Label("悬浮球", systemImage: "record.circle")
                        .font(.footnote.weight(.medium))
                }
                .buttonStyle(.bordered)
            }
            statusRow
            LevelMeter(db: audio.levelDB)
            dictationBar
            metrics
            pipRow
            actionButton
            webhookBar
            asrBar
            logPanel
        }
        .padding(.horizontal, 48)
        .padding(.vertical, 26)
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
                        .stroke(Color(uiColor: .separator), lineWidth: 0.5)
                )
            VStack(alignment: .leading, spacing: 4) {
                Text("桌面悬浮窗")
                    .font(.subheadline.bold())
                Text("点右上「悬浮球」，App 缩成画中画小窗浮在桌面/其他 App 上方；点小窗的展开按钮返回。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .frame(maxWidth: 620)
    }

    // MARK: - 区块

    private var header: some View {
        VStack(spacing: 6) {
            Text("麦克风采集探针")
                .font(.system(size: 34, weight: .bold))
            Text("16 kHz · 单声道 · 512 样本/帧 · 唤醒词「\(Config.wakeWord)」")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var statusRow: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(statusColor)
                .frame(width: 13, height: 13)
            Text(audio.stateText)
                .font(.title3.weight(.medium))
        }
    }

    private var statusColor: Color {
        if audio.isWakeupActive { return .green }
        return audio.isRunning ? Color.red : Color(uiColor: .systemGray3)
    }

    private var metrics: some View {
        HStack(spacing: 32) {
            metric(title: "电平", value: String(format: "%.1f dBFS", audio.levelDB))
            metric(title: "已处理帧", value: "\(audio.frameCount)")
            metric(title: "唤醒",
                   value: "\(audio.wakeupCount) 次")
            metric(title: "时长",
                   value: String(format: "%.1f s",
                                 Double(audio.frameCount * Config.frameSize) / Config.sampleRate))
        }
    }

    private func metric(title: String, value: String) -> some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 20, weight: .semibold, design: .monospaced))
        }
        .frame(minWidth: 120)
    }

    private var actionButton: some View {
        Button {
            if audio.isRunning { audio.stop() } else { audio.start() }
        } label: {
            Text(audio.isRunning ? "停止采集" : "开始采集")
                .font(.title3.bold())
                .frame(width: 260)
                .padding(.vertical, 16)
        }
        .buttonStyle(.borderedProminent)
        .tint(audio.isRunning ? Color(uiColor: .systemGray) : .accentColor)
    }

    /// 速记进行中：显示实时转写文本与操作提示
    @ViewBuilder
    private var dictationBar: some View {
        if audio.isDictating {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "mic.fill")
                        .foregroundStyle(.orange)
                    Text("速记中…说「结束 / 发送完毕」发送")
                        .font(.footnote.bold())
                        .foregroundStyle(.orange)
                }
                Text(audio.dictationText.isEmpty ? "（原声录音中…）" : audio.dictationText)
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(Color(uiColor: .secondarySystemGroupedBackground))
                    .cornerRadius(10)
            }
        }
    }

    /// 飞书 Webhook 设置栏：粘贴群机器人地址 + 测试按钮
    private var webhookBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "bell.badge")
                .foregroundStyle(.secondary)
            TextField("飞书通知：粘贴 Webhook 地址，或 AppID,AppSecret（机器人名义私聊发给你）",
                      text: $webhookDraft)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 14))
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
                    .font(.callout.bold())
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: 620)
    }

    /// 局域网转写服务自检
    private var asrBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .foregroundStyle(.secondary)
            Text("转写服务 \(RemoteASR.serverHost)")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
            Button {
                audio.checkASR()
            } label: {
                Text("网络自检")
                    .font(.callout.bold())
            }
            .buttonStyle(.bordered)
            Spacer()
        }
        .frame(maxWidth: 620)
    }

    private var logPanel: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 3) {
                ForEach(audio.logs.indices, id: \.self) { i in
                    Text(audio.logs[i])
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(14)
        }
        .frame(maxWidth: 620, maxHeight: 160)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color(uiColor: .separator), lineWidth: 0.5)
        )
    }
}

/// 画中画视频层的宿主视图（内嵌预览）
struct PiPHostView: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView { PiPBubble.shared.containerView() }
    func updateUIView(_ uiView: UIView, context: Context) {}
}

/// 电平条：-60 dBFS ~ 0 dBFS 映射到 0 ~ 1 宽度
struct LevelMeter: View {
    let db: Float

    private var normalized: CGFloat {
        let clamped = max(-60, min(0, Double(db)))
        return CGFloat((clamped + 60) / 60)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 9)
                    .fill(Color(uiColor: .systemGray5))
                RoundedRectangle(cornerRadius: 9)
                    .fill(normalized > 0.85 ? Color.red : Color.green)
                    .frame(width: max(0, geo.size.width * normalized))
                    .animation(.linear(duration: 0.06), value: normalized)
            }
        }
        .frame(height: 26)
        .frame(maxWidth: 620)
    }
}
