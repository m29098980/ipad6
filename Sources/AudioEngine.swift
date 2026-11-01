import AVFoundation
import AVFAudio
import Combine
import UIKit

/// 麦克风采集 → 重采样到 16 kHz → 切 512 样本帧 → 算电平 / 可选上传
///
/// 线程模型：
/// - AVAudioEngine 的 tap 回调在实时音频线程，绝不做重活，只把 buffer 丢给 processQueue
/// - 重采样、分帧、电平计算都在 processQueue 串行执行
/// - 所有 @Published 属性只在主线程写
final class AudioEngine: ObservableObject {

    // MARK: - 对外状态

    @Published private(set) var isRunning = false
    @Published private(set) var levelDB: Float = -120
    @Published private(set) var frameCount: Int = 0
    @Published private(set) var stateText: String = "待机"
    @Published private(set) var logs: [String] = []
    @Published private(set) var wakeupCount: Int = 0
    @Published private(set) var isWakeupActive = false

    // MARK: - 内部

    private let engine = AVAudioEngine()
    private let kws = KwsEngine()
    private var kwsReady = false
    private let processQueue = DispatchQueue(label: "com.jychan.micprobe.audio", qos: .userInitiated)

    private let targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                             sampleRate: Config.sampleRate,
                                             channels: 1,
                                             interleaved: true)!

    private var converter: AVAudioConverter?
    private var tapInstalled = false

    /// 待切帧的样本缓冲；用读指针避免 removeFirst 的 O(n) 拷贝
    private var pending: [Int16] = []
    private var readIndex = 0

    private var uploadBatch: [Int16] = []
    private var uplink: Uplink?
    private var uiTick = 0
    private var lastErrorAt: TimeInterval = 0

    // MARK: - 生命周期

    func start() {
        guard !isRunning else { return }
        // iOS 17 起统一用 AVAudioApplication 申请录音权限
        AVAudioApplication.requestRecordPermission { granted in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if granted {
                    self.beginCapture()
                } else {
                    self.stateText = "麦克风权限被拒绝"
                    self.append("请在 设置 → 隐私与安全性 → 麦克风 里允许 MicProbe")
                }
            }
        }
    }

    private func beginCapture() {
        NSLog("MPBOX: beginCapture enter")
        do {
            try configureSession()
            NSLog("MPBOX: step1 session ok")
            try startEngine()
            NSLog("MPBOX: step2 engine ok")
            uplink = Config.uploadURL.isEmpty ? nil : Uplink(urlString: Config.uploadURL)

            UIApplication.shared.isIdleTimerDisabled = true   // 屏幕常亮
            isRunning = true
            stateText = "监听中"

            append("已启动，输入采样率 \(Int(AVAudioSession.sharedInstance().sampleRate)) Hz")
            if uplink == nil { append("未配置上传地址，仅本地统计电平") }

            // 唤醒词引擎：只初始化一次，失败不阻塞采集
            if !kwsReady {
                NSLog("MPBOX: step3 kws init begin")
                if let err = kws.setup() {
                    append("唤醒词引擎初始化失败：\(err)")
                    NSLog("MPBOX: step3 kws init FAIL \(err)")
                } else {
                    kwsReady = true
                    append("唤醒词引擎就绪，监听「\(Config.wakeWord)」")
                    NSLog("MPBOX: step3 kws init ok")
                }
            }
            NSLog("MPBOX: beginCapture done")
        } catch {
            // 引擎启动失败时可能已经装了 tap，必须摘掉，否则下次开始会因重复安装崩溃
            if tapInstalled {
                engine.inputNode.removeTap(onBus: 0)
                tapInstalled = false
            }
            engine.stop()
            stateText = "启动失败"
            append("启动失败：\(error.localizedDescription)")
        }
    }

    func stop() {
        guard isRunning else { return }
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)

        DispatchQueue.main.async {
            UIApplication.shared.isIdleTimerDisabled = false
            self.isRunning = false
            self.stateText = "已停止"
            self.levelDB = -120
        }
        append("已停止，累计 \(frameCount) 帧")
    }

    // MARK: - 会话与引擎

    private func configureSession() throws {
        let session = AVAudioSession.sharedInstance()
        // .measurement 关闭系统音效处理（AGC / 降噪），拿到更接近原始的波形，适合做特征
        try session.setCategory(.playAndRecord,
                                mode: .measurement,
                                options: [.defaultToSpeaker, .allowBluetoothA2DP])
        try session.setPreferredSampleRate(Config.sampleRate)
        try session.setPreferredIOBufferDuration(0.02)
        try session.setActive(true)
    }

    private func startEngine() throws {
        let input = engine.inputNode
        let hwFormat = input.outputFormat(forBus: 0)

        guard hwFormat.sampleRate > 0, hwFormat.channelCount > 0 else {
            throw NSError(domain: "MicProbe", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "没有可用的音频输入通道，检查麦克风是否被占用"])
        }

        guard let conv = AVAudioConverter(from: hwFormat, to: targetFormat) else {
            throw NSError(domain: "MicProbe", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "无法创建重采样器（\(Int(hwFormat.sampleRate)) Hz → \(Int(Config.sampleRate)) Hz）"])
        }
        conv.sampleRateConverterQuality = AVAudioQuality.medium.rawValue
        conv.primeMethod = .none
        // 外接 USB 麦克风常报 2 声道；AVAudioConverter 不会自动混音，必须显式下混到 1 声道
        if hwFormat.channelCount > 1 {
            conv.channelMap = [0]
            conv.downmix = true
        }
        converter = conv

        append("硬件格式 \(Int(hwFormat.sampleRate)) Hz / \(hwFormat.channelCount) ch → 目标 \(Int(Config.sampleRate)) Hz / 1 ch")

        input.installTap(onBus: 0, bufferSize: 1024, format: hwFormat) { [weak self] buffer, _ in
            guard let self else { return }
            self.processQueue.async { self.convert(buffer) }
        }
        tapInstalled = true

        engine.prepare()
        try engine.start()
    }

    // MARK: - 重采样与分帧（processQueue 上执行）

    private func convert(_ input: AVAudioPCMBuffer) {
        guard let converter else { return }

        let ratio = targetFormat.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

        var supplied = false
        var convError: NSError?
        let status = converter.convert(to: out, error: &convError) { _, outStatus in
            if supplied {
                outStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            outStatus.pointee = .haveData
            return input
        }

        if let convError {
            reportOnce("重采样失败：\(convError.localizedDescription)")
            return
        }
        guard status != .error, out.frameLength > 0, let ch = out.int16ChannelData?[0] else { return }

        pending.append(contentsOf: UnsafeBufferPointer(start: ch, count: Int(out.frameLength)))
        drainFrames()
    }

    private func drainFrames() {
        let n = Config.frameSize
        while pending.count - readIndex >= n {
            let start = readIndex
            let frame = Array(pending[start ..< (start + n)])
            readIndex += n
            handleFrame(frame)
        }
        // 回收已经消费的前缀，避免数组无限膨胀
        if readIndex > n * 128 {
            pending.removeFirst(readIndex)
            readIndex = 0
        }
    }

    private func handleFrame(_ frame: [Int16]) {
        // RMS → dBFS
        var sum: Double = 0
        for s in frame {
            let v = Double(s) / 32_768.0
            sum += v * v
        }
        let rms = (sum / Double(frame.count)).squareRoot()
        let db = 20.0 * log10(max(rms, 1e-7))

        uiTick += 1
        if uiTick % Config.uiTickInterval == 0 {
            DispatchQueue.main.async {
                self.levelDB = Float(db)
                self.frameCount += 1
            }
        }

        // 唤醒词检测（同在 processQueue 串行执行）
        if kwsReady, let kw = kws.feed(frame) {
            DispatchQueue.main.async {
                self.wakeupCount += 1
                self.onWakeup(kw)
            }
        }

        // 可选：攒批上传原始 PCM
        if let uplink {
            uploadBatch.append(contentsOf: frame)
            let threshold = Config.frameSize * Config.framesPerUpload
            if uploadBatch.count >= threshold {
                let chunk = uploadBatch
                uploadBatch.removeAll(keepingCapacity: true)
                uplink.send(pcm: chunk)
            }
        }
    }

    // MARK: - 唤醒命中

    private func onWakeup(_ keyword: String) {
        stateText = "听到：\(keyword)"
        isWakeupActive = true
        append("🔔 唤醒命中：\(keyword)（第 \(wakeupCount) 次）")

        // 飞书群机器人通知
        let fmt = DateFormatter()
        fmt.dateFormat = "MM-dd HH:mm:ss"
        let msg = "🔔 MicProbe 唤醒命中「\(keyword)」\n时间：\(fmt.string(from: Date()))\n第 \(wakeupCount) 次唤醒"
        Feishu.send(text: msg) { [weak self] err in
            if let err {
                self?.append("飞书通知失败：\(err)")
            } else {
                self?.append("飞书通知已发送 ✓")
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(Config.wakeupFlashSeconds)) { [weak self] in
            guard let self, self.isRunning else { return }
            self.isWakeupActive = false
            self.stateText = "监听中"
        }
    }

    /// 供界面设置栏写日志（如 Webhook 测试结果）
    func logPublic(_ line: String) {
        append(line)
    }

    // MARK: - 日志

    private func append(_ line: String) {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm:ss"
        let text = "[\(fmt.string(from: Date()))] \(line)"
        DispatchQueue.main.async {
            self.logs.append(text)
            if self.logs.count > 200 { self.logs.removeFirst(self.logs.count - 200) }
        }
    }

    private func reportOnce(_ message: String) {
        let now = Date().timeIntervalSince1970
        guard now - lastErrorAt > 5 else { return }
        lastErrorAt = now
        append(message)
    }
}
