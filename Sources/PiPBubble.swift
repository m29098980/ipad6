import AVKit
import AVFoundation
import UIKit

/// 画中画悬浮球。
///
/// iOS 不允许 App 窗口透明后透出桌面（透明区域只会露出黑白底板），
/// 所以「悬浮透明迷你界面」用画中画（PiP）方案实现：
/// 把采集状态渲染成视频帧喂给 AVSampleBufferDisplayLayer，
/// 通过 AVPictureInPictureController 缩成系统画中画小窗——
/// 真正浮在桌面 / 任意 App 上方，可拖动，点小窗回到完整界面。
///
/// 画面内容：深色底 + 状态圆点（绿=监听 / 橙=速记中 / 灰=已停止）+ 状态文字。
@MainActor
final class PiPBubble: NSObject {

    static let shared = PiPBubble()

    private let displayLayer = AVSampleBufferDisplayLayer()
    private var pipController: AVPictureInPictureController?
    private var format: CMFormatDescription?
    private var timer: Timer?
    private var possibleObservation: NSKeyValueObservation?
    private var autoStartRequested = false
    private weak var audio: AudioEngine?
    private weak var hostView: UIView?

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

    /// 启动帧渲染（状态变化时画面每 0.5 秒刷新）
    func attach(audio: AudioEngine) {
        guard timer == nil else { return }
        self.audio = audio
        setupPiP()
        renderNow()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.renderNow()
            }
        }
    }

    /// 点「悬浮球」按钮：进入画中画小窗。
    /// 四重保障：直接启动 → KVO 等画面就绪自动启动 → 0.8 秒未生效则退到桌面
    /// （canStartPictureInPictureAutomaticallyFromInline 会在退后台时自动进入）→ 提示按 Home。
    func startPresentation() {
        setupPiP()
        renderNow()
        guard let pip = pipController else { return }
        autoStartRequested = true
        let supported = AVPictureInPictureController.isPictureInPictureSupported()
        onLog?("悬浮窗：supported=\(supported) possible=\(pip.isPictureInPicturePossible)")
        tryStartOrWait()
    }

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
    private func suspendToHome() {
        let sel = Selector(("suspend"))
        guard UIApplication.shared.responds(to: sel) else {
            onLog?("请按 Home 键回到桌面，悬浮窗会自动出现")
            return
        }
        UIApplication.shared.perform(sel)
        onLog?("已回到桌面，悬浮窗应已出现；点小窗的展开按钮可回到本 App")
    }

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

    // MARK: - 帧渲染

    private var tick = 0

    private func statusInfo() -> (String, UIColor, Bool) {
        // 返回 (标题, 主题色, 是否速记状态)
        guard let a = audio else { return ("已停止", .systemGray, false) }
        if a.isDictating || a.isWakeupActive { return ("速记中", .orange, true) }
        return a.isRunning ? ("监听中", .green, false) : ("已停止", .systemGray, false)
    }

    private func renderNow() {
        tick += 1
        let (label, color, active) = statusInfo()
        let pulse = (tick / 2) % 2 == 0   // 每 1 秒明暗交替，闪烁提示

        // 速记已录秒数
        var elapsed = -1
        if active, let start = audio?.dictationStartedDate {
            elapsed = Int(Date().timeIntervalSince(start))
        }

        let size = CGSize(width: frameW, height: frameH)
        let renderer = UIGraphicsImageRenderer(size: size)
        let img = renderer.image { c in
            let full = CGRect(origin: .zero, size: size)

            // 底色：速记=亮橙（远处一眼可见）；监听=深色
            if active {
                UIColor.orange.setFill()
                c.fill(full)
            } else {
                UIColor(red: 0.08, green: 0.09, blue: 0.11, alpha: 1).setFill()
                c.fill(full)
            }

            // 高亮边框环：让小窗在任何壁纸上都醒目
            c.cgContext.setStrokeColor(active
                ? UIColor.white.cgColor
                : color.withAlphaComponent(pulse ? 1.0 : 0.35).cgColor)
            c.cgContext.setLineWidth(10)
            c.cgContext.stroke(full.insetBy(dx: 5, dy: 5))

            // 状态圆点（速记时做脉冲缩放）
            let dotR: CGFloat = active ? (pulse ? 30 : 22) : (pulse ? 26 : 20)
            color.setFill()
            c.cgContext.fillEllipse(in: CGRect(x: 52 - dotR / 2 + 24,
                                               y: frameH / 2 - dotR / 2,
                                               width: dotR, height: dotR))

            // 主标题
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 56, weight: .bold),
                .foregroundColor: active ? UIColor.white : UIColor.white
            ]
            (label as NSString).draw(at: CGPoint(x: 118, y: frameH / 2 - 62), withAttributes: attrs)

            // 副行：速记时显示录音秒数（跳动），监听时显示唤醒词提示
            let sub: String
            if active {
                sub = "● REC \(elapsed)s"
            } else {
                sub = "「85号」唤醒"
            }
            let subAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.monospacedDigitSystemFont(ofSize: 34, weight: .semibold),
                .foregroundColor: active
                    ? (pulse ? UIColor.white : UIColor(white: 1, alpha: 0.75))
                    : UIColor(white: 1, alpha: 0.6)
            ]
            (sub as NSString).draw(at: CGPoint(x: 118, y: frameH / 2 + 8), withAttributes: subAttrs)

            // 底部提示小字
            let tip: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 20, weight: .regular),
                .foregroundColor: UIColor(white: 1, alpha: 0.5)
            ]
            ("说「结束」或「发送完毕」发送" as NSString)
                .draw(at: CGPoint(x: 56, y: frameH - 42), withAttributes: tip)
        }
        guard let cg = img.cgImage else { return }

        // 画进 CVPixelBuffer（BGRA）
        var pbBox: CVPixelBuffer?
        let createStatus = CVPixelBufferCreate(kCFAllocatorDefault, frameW, frameH,
                                               kCVPixelFormatType_32BGRA, nil, &pbBox)
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
            var fmtOut: CMFormatDescription?
            let st = CMVideoFormatDescriptionCreate(
                allocator: kCFAllocatorDefault,
                codecType: kCMVideoCodecType_MPEG4Video,
                width: Int32(frameW),
                height: Int32(frameH),
                extensions: nil,
                formatDescriptionOut: &fmtOut)
            guard st == noErr, let fmt = fmtOut else { return }
            format = fmt
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
        guard st == noErr, let sb = sbBox else { return }
        displayLayer.enqueue(sb)
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
