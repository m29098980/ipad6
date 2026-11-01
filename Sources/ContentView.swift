import SwiftUI

struct ContentView: View {
    @ObservedObject var audio: AudioEngine

    var body: some View {
        VStack(spacing: 26) {
            header
            statusRow
            LevelMeter(db: audio.levelDB)
            metrics
            actionButton
            logPanel
        }
        .padding(.horizontal, 48)
        .padding(.vertical, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemGroupedBackground))
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
        .frame(maxWidth: 620, maxHeight: 200)
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
