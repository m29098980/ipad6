import AVKit
import AVFoundation
import UIKit
import os.log

/// 画中画悬浮球。
///
/// iOS 不允许 App 窗口透明后透出桌面（透明区域只会露出黑白底板），
/// 所以「悬浮透明迷你界面」用画中画（PiP）方案实现：
/// 把采集状态渲染成视频帧喂给 AVSampleBufferDisplayLayer，
/// 通过 AVPictureInPictureController 缩成系统画中画小窗——
/// 真正浮在桌面 / 任意 App 上方，可拖动，点小窗回到完整界面。
///
/// 关键：帧渲染必须跑在【后台串行队列】上。
/// 之前用主线程 Timer，App 退到后台后主线程 RunLoop 被冻结，
/// 小窗画面停在最后一帧——唤醒后用户永远看不到状态变化。
/// App 有 audio 后台模式，进程在后台存活，后台队列的定时器不会被冻结。
final class PiPBubble: NSObject {

    static let shared = PiPBubble()

    /// 远程诊断日志（syslog 可见，电脑端 pymobiledevice3 syslog live 可抓）
    private let log = Logger(subsystem: "com.jychan.micprobe", category: "pip")

    private let displayLayer = AVSampleBufferDisplayLayer()
    private var pipController: AVPictureInPictureController?
    private var format: CMFormatDescription?
    private var possibleObservation: NSKeyValueObservation?
    private var autoStartRequested = false
    private weak var audio: AudioEngine?
    private weak var hostView: UIView?

    /// 后台渲染队列与定时器（后台不冻结的关键）
    private let renderQueue = DispatchQueue(label: "pip.render", qos: .userInteractive)
    private var renderTimer: DispatchSourceTimer?

    /// 日志回传给界面
    var onLog: ((String) -> Void)?

    /// 视频帧尺寸（16:9，PiP 小窗按此比例渲染）
    private let frameW = 480
    private let frameH = 270
    /// 内嵌预览窗尺寸
    private let previewW: CGFloat = 144
    private let previewH: CGFloat = 81

    // MARK: - 挂载与展示

    /// 携带视频层的容器视图（SwiftUI 里用 UIViewRepresentable 嵌入做内嵌预览）
    @MainActor
    func containerView() -> UIView {
        if let hostView { return hostView }
        let v = UIView(frame: CGRect(x: 0, y: 0, width: previewW, height: previewH))
        v.backgroundColor = .clear
        displayLayer.videoGravity = .resizeAspect
        displayLayer.frame = v.bounds
        v.layer.addSublayer(displayLayer)
        hostView = v
        return v
    }

    /// 启动帧渲染（后台队列每 0.5 秒刷新一帧，前后台都不停）
    @MainActor
    func attach(audio: AudioEngine) {
        guard renderTimer == nil else { return }
        self.audio = audio
        setupPiP()
        startRenderLoop()
    }

    /// 点「悬浮球」按钮：进入画中画小窗。
    /// 四重保障：直接启动 → KVO 等画面就绪自动启动 → 0.8 秒未生效则退到桌面
    /// （canStartPictureInPictureAutomaticallyFromInline 会在退后台时自动进入）→ 提示按 Home。
    @MainActor
    func startPresentation() {
        setupPiP()
        renderOnQueue()
        guard let pip = pipController else { return }
        autoStartRequested = true
        let supported = AVPictureInPictureController.isPictureInPictureSupported()
        log.info("startPresentation: supported=\(supported, privacy: .public) possible=\(pip.isPictureInPicturePossible, privacy: .public)")
        onLog?("悬浮窗：supported=\(supported) possible=\(pip.isPictureInPicturePossible)")
        tryStartOrWait()
    }

    @MainActor
    private func tryStartOrWait() {
        guard let pip = pipController else { return }
        if pip.isPictureInPicturePossible {
            pip.startPictureInPicture()
            // 0.8 秒后仍未进入画中画 → 主动退到后台，触发「自动从内嵌进入画中画」
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                guard let self, let pip = self.pipController, !pip.isPictureInPictureActive else { return }
                self.suspendToHome()
            }
        } else if autoStartRequested {
            // 画面缓冲未就绪：监听 isPictureInPicturePossible，一就绪立刻自动启动
            if possibleObservation == nil {
                possibleObservation = pip.observe(\.isPictureInPicturePossible, options: [.new]) { [weak self] observed, _ in
                    Task { @MainActor in
                        guard let self else { return }
                        if observed.isPictureInPicturePossible, self.autoStartRequested {
                            self.tryStartOrWait()
                        }
                    }
                }
            }
            onLog?("悬浮窗画面准备中，就绪后自动进入（也可直接按 Home 键）")
        }
    }

    /// 把 App 退到后台（回到桌面）。私有 suspend 选择器，侧载应用可用。
    @MainActor
    private func suspendToHome() {
        let sel = Selector(("suspend"))
        guard UIApplication.shared.responds(to: sel) else {
            onLog?("请按 Home 键回到桌面，悬浮窗会自动出现")
            return
        }
        UIApplication.shared.perform(sel)
        onLog?("已回到桌面，悬浮窗应已出现；点小窗的展开按钮可回到本 App")
    }

    @MainActor
    private func setupPiP() {
        guard pipController == nil else { return }
        guard AVPictureInPictureController.isPictureInPictureSupported() else {
            onLog?("此设备不支持画中画悬浮窗")
            return
        }
        let source = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: displayLayer,
            playbackDelegate: self)
        let pip = AVPictureInPictureController(contentSource: source)
        pip.canStartPictureInPictureAutomaticallyFromInline = true  // 按 Home 自动进 PiP
        pipController = pip
    }

    /// 启动后台渲染循环（前后台都不停）
    @MainActor
    private func startRenderLoop() {
        guard renderTimer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: renderQueue)
        t.schedule(deadline: .now(), repeating: 0.5)
        t.setEventHandler { [weak self] in
            self?.renderOnQueue()
        }
        t.resume()
        renderTimer = t
    }

    // MARK: - 帧渲染（后台队列执行）

    private var tick = 0

    /// 在渲染队列上执行的一帧：读状态 → 画图 → 入队
    /// AudioEngine 的状态是简单值类型（Bool/Date/Int），跨线程读实际安全，
    /// 且工程 SWIFT_STRICT_CONCURRENCY=minimal 不拦截。
    private func renderOnQueue() {
        tick += 1
        let a = audio
        let dictating = a?.isDictating ?? false
        let wakeupActive = a?.isWakeupActive ?? false
        let running = a?.isRunning ?? false
        let started = a?.dictationStartedDate

        let active = dictating || wakeupActive
        let label: String
        let color: UIColor
        if active {
            label = "速记中"
            color = .orange
        } else if running {
            label = "监听中"
            color = .green
        } else {
            label = "已停止"
            color = .systemGray
        }
        var elapsed = -1
        if active, let start = started {
            elapsed = Int(Date().timeIntervalSince(start))
        }
        let pulse = (tick / 2) % 2 == 0   // 每 1 秒明暗交替，闪烁提示

        let size = CGSize(width: frameW, height: frameH)
        let renderer = UIGraphicsImageRenderer(size: size)
        let img = renderer.image { c in
            self.drawBackground(c, active: active)
            self.drawBorder(c, color: color, active: active, pulse: pulse)
            self.drawDot(c, color: color, active: active, pulse: pulse)
            self.drawLabel(c, label: label, sub: active ? "● REC \(elapsed)s" : "「Bavo」唤醒",
                           active: active, pulse: pulse)
            self.drawTip(c, active: active)
        }
        guard let cg = img.cgImage else { return }

        // 画进 CVPixelBuffer（BGRA）
        // 关键修复 3：必须带 IOSurface 属性创建。
        // 画中画渲染走跨进程视频队列（App 进程 → mediaplaybackd），
        // 无 IOSurface 背板的缓冲无法跨进程传输 → 图层本地入队正常、系统队列 0 帧 → 窗口纯黑。
        var pbBox: CVPixelBuffer?
        var bufAttrs = [String: Any]()
        bufAttrs[String(kCVPixelBufferIOSurfacePropertiesKey)] = [String: Any]()
        let createStatus = CVPixelBufferCreate(kCFAllocatorDefault, frameW, frameH,
                                               kCVPixelFormatType_32BGRA,
                                               bufAttrs as CFDictionary, &pbBox)
        guard createStatus == noErr, let pb = pbBox else { return }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb),
                                  width: frameW, height: frameH,
                                  bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                            | CGBitmapInfo.byteOrder32Little.rawValue) else { return }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: frameW, height: frameH))
        enqueue(pb)
    }

    private func enqueue(_ pb: CVPixelBuffer) {
        if format == nil {
            // 关键修复：未压缩像素缓冲必须用 CreateForImageBuffer 建格式说明。
            // 之前误用 kCMVideoCodecType_MPEG4Video（压缩视频格式），
            // 系统把 BGRA 图像帧当坏数据全部丢弃 → 画中画等不到画面 → -1003 启动失败。
            var fmtOut: CMFormatDescription?
            let st = CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: pb,
                formatDescriptionOut: &fmtOut)
            guard st == noErr, let fmt = fmtOut else {
                log.error("format create failed, status=\(st, privacy: .public)")
                return
            }
            format = fmt
            log.info("format created OK (image-buffer backed)")
        }
        guard let fmt = format else { return }
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 2),
            presentationTimeStamp: CMClock.hostTimeClock.time,
            decodeTimeStamp: .invalid)
        var sbBox: CMSampleBuffer?
        let st = CMSampleBufferCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pb,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: fmt,
            sampleTiming: &timing,
            sampleBufferOut: &sbBox)
        guard st == noErr, let sb = sbBox else {
            log.error("sample buffer create failed, status=\(st, privacy: .public)")
            return
        }
        // 关键修复 2：打「立即显示」标记。
        // 不打标记时系统按时间戳排期显示，画中画管线下时间基准错位 → 帧永远排不上 → 纯黑。
        // （已知问题：https://stackoverflow.com/questions/38364656）
        if let arr = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: true) {
            if CFArrayGetCount(arr) > 0 {
                let dict = unsafeBitCast(CFArrayGetValueAtIndex(arr, 0),
                                         to: CFMutableDictionary.self)
                CFDictionarySetValue(dict,
                                     Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                     Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
            }
        }
        guard displayLayer.isReadyForMoreMediaData else {
            if tick % 4 == 0 { log.info("tick=\(self.tick, privacy: .public) layer not ready, skip") }
            return
        }
        displayLayer.enqueue(sb)
        // 每 2 秒向 syslog 汇报一次入队与图层状态，便于远程诊断
        if tick % 4 == 0 {
            let status = displayLayer.status.rawValue
            let err = displayLayer.error?.localizedDescription ?? "none"
            log.info("tick=\(self.tick, privacy: .public) enqueued OK, layerStatus=\(status, privacy: .public), layerError=\(err, privacy: .public)")
        }
    }

    // MARK: - 绘制子步骤（拆小函数避免编译器类型检查超时）

    private func drawBackground(_ c: UIGraphicsImageRendererContext, active: Bool) {
        let full = CGRect(x: 0, y: 0, width: frameW, height: frameH)
        if active {
            // 激活：高亮橙 + 红色渐变边缘，一眼可辨
            UIColor(red: 1.0, green: 0.42, blue: 0.05, alpha: 1).setFill()
        } else {
            UIColor(red: 0.08, green: 0.09, blue: 0.11, alpha: 1).setFill()
        }
        c.fill(full)
    }

    private func drawBorder(_ c: UIGraphicsImageRendererContext, color: UIColor,
                            active: Bool, pulse: Bool) {
        let full = CGRect(x: 0, y: 0, width: frameW, height: frameH)
        let strokeColor: UIColor = active
            ? (pulse ? .white : UIColor(red: 1.0, green: 0.95, blue: 0.7, alpha: 1))
            : color.withAlphaComponent(pulse ? 1.0 : 0.35)
        c.cgContext.setStrokeColor(strokeColor.cgColor)
        c.cgContext.setLineWidth(active ? 16 : 10)
        c.cgContext.stroke(full.insetBy(dx: active ? 8 : 5, dy: active ? 8 : 5))
    }

    private func drawDot(_ c: UIGraphicsImageRendererContext, color: UIColor,
                         active: Bool, pulse: Bool) {
        var radius: CGFloat = 22
        if pulse { radius = active ? 34 : 26 }
        let x: CGFloat = 76 - radius / 2
        let y = CGFloat(frameH) / 2 - radius / 2
        color.setFill()
        c.cgContext.fillEllipse(in: CGRect(x: x, y: y, width: radius, height: radius))
    }

    private func drawLabel(_ c: UIGraphicsImageRendererContext, label: String, sub: String,
                           active: Bool, pulse: Bool) {
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 56, weight: .bold),
            .foregroundColor: UIColor.white
        ]
        (label as NSString).draw(at: CGPoint(x: 118, y: CGFloat(frameH) / 2 - 62),
                                 withAttributes: titleAttrs)

        let subColor: UIColor
        if active {
            subColor = pulse ? .white : UIColor(white: 1, alpha: 0.8)
        } else {
            subColor = UIColor(white: 1, alpha: 0.6)
        }
        let subAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedDigitSystemFont(ofSize: 36, weight: .bold),
            .foregroundColor: subColor
        ]
        (sub as NSString).draw(at: CGPoint(x: 118, y: CGFloat(frameH) / 2 + 8),
                               withAttributes: subAttrs)
    }

    private func drawTip(_ c: UIGraphicsImageRendererContext, active: Bool) {
        let tipAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 20, weight: .regular),
            .foregroundColor: UIColor(white: 1, alpha: active ? 0.85 : 0.5)
        ]
        let tip = active ? "正在录音…说「结束」发送" : "说「巴沃 / 把握」开始速记"
        (tip as NSString).draw(at: CGPoint(x: 56, y: CGFloat(frameH) - 42), withAttributes: tipAttrs)
    }
}

// MARK: - PiP 播放代理
// 协议 required 成员同时存在「方法形式」与「属性形式」两代 API，
// 这里全量实现两者，保证在任何 SDK 版本下都满足 conformance。
// skipByInterval 为 optional，不实现。

extension PiPBubble: AVPictureInPictureSampleBufferPlaybackDelegate {

    // ---- 方法形式（Apple 文档标注 Required）----

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                    setPlaying playing: Bool) {}

    func pictureInPictureControllerTimeRangeForPlayback(_ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
        CMTimeRange(start: .zero, duration: CMTime(value: 1, timescale: 2))
    }

    func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController: AVPictureInPictureController) -> Bool {
        false
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                    didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}

    // ---- skipByInterval（required，Swift 标签 completion:）----

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                    skipByInterval skipInterval: CMTime,
                                    completion: @escaping () -> Void) {
        completion()
    }

    // ---- 属性形式（旧版 SDK 的 required 成员）----

    var isPlaybackPaused: Bool { false }
    var timeRange: CMTimeRange { CMTimeRange(start: .zero, duration: CMTime(value: 1, timescale: 2)) }
    var duration: CMTime { CMTime(value: 1, timescale: 2) }
    var playbackRate: Float { 1.0 }
    var isPlaybackBufferEmpty: Bool { false }
    var isPlaybackBufferFull: Bool { true }

    func pictureInPictureControllerTimeControlDidChanged(_ pictureInPictureController: AVPictureInPictureController) {}
}

// MARK: - PiP 生命周期代理

extension PiPBubble: AVPictureInPictureControllerDelegate {

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                    failedToStartPictureInPictureWithError error: Error) {
        log.error("PiP failed to start: \(error.localizedDescription, privacy: .public)")
        onLog?("悬浮窗启动失败：\(error.localizedDescription)")
    }

    /// 点画中画小窗的「展开」按钮回到 App：恢复完整界面
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        autoStartRequested = false
        completionHandler(true)
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        autoStartRequested = false
    }
}
