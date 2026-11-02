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

    /// 点「悬浮球」按钮：直接进入画中画小窗
    func startPresentation() {
        setupPiP()
        renderNow()
        guard let pip = pipController else { return }
        if pip.isPictureInPicturePossible {
            pip.startPictureInPicture()
        } else {
            onLog?("悬浮窗还没就绪（画面缓冲中），稍等 1 秒再点一次，或直接按 Home 键回桌面自动进入")
        }
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

    private func statusInfo() -> (String, UIColor) {
        guard let a = audio else { return ("已停止", .systemGray) }
        if a.isDictating || a.isWakeupActive { return ("速记中", .orange) }
        return a.isRunning ? ("监听中", .green) : ("已停止", .systemGray)
    }

    private func renderNow() {
        let (label, color) = statusInfo()

        let size = CGSize(width: frameW, height: frameH)
        let renderer = UIGraphicsImageRenderer(size: size)
        let img = renderer.image { c in
            // 深色底
            UIColor(red: 0.10, green: 0.10, blue: 0.12, alpha: 1).setFill()
            c.fill(CGRect(origin: .zero, size: size))
            // 状态圆点
            color.setFill()
            c.cgContext.fillEllipse(in: CGRect(x: 56, y: frameH / 2 - 24, width: 48, height: 48))
            // 状态文字
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 54, weight: .semibold),
                .foregroundColor: UIColor.white
            ]
            (label as NSString).draw(at: CGPoint(x: 130, y: frameH / 2 - 34), withAttributes: attrs)
            // 底部提示小字
            let tip: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 22, weight: .regular),
                .foregroundColor: UIColor(white: 1, alpha: 0.55)
            ]
            ("「85号」开始 ·「结束/发送/完毕」发送" as NSString)
                .draw(at: CGPoint(x: 56, y: frameH - 46), withAttributes: tip)
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
        completionHandler(true)
    }
}
