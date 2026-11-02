import Foundation

/// 全局采集参数。唤醒词引擎（Porcupine 等）统一以 16 kHz / 单声道 / Int16 为准，
/// 所以这里把重采样目标写死，后续接入任何引擎都不用再改。
enum Config {

    /// 目标采样率（Hz）
    static let sampleRate: Double = 16_000

    /// 单帧样本数：512 = 32 ms，与 Porcupine 的 frameLength 一致
    static let frameSize: Int = 512

    /// 上传地址。留空则只在本地统计电平，不发任何网络请求。
    /// 例：http://10.168.1.13:8080/audio
    static let uploadURL: String = ""

    /// 攒够多少帧发一次（512 帧 × 32 ms ≈ 16.4 秒）
    static let framesPerUpload: Int = 512

    /// 唤醒词文本（界面显示用，与 Model/keywords.txt 保持一致）
    static let wakeWord = "85号"

    /// 唤醒命中后状态灯保持高亮秒数
    static let wakeupFlashSeconds = 3

    /// 界面电平刷新节流：每 N 帧更新一次 UI（3 帧 ≈ 10 Hz）
    static let uiTickInterval: Int = 3

    /// 诊断用：启动后自动开始采集（无人值守测试）。定位问题后改回 false。
    static let autoStartOnLaunch = true

    /// 飞书应用模式的默认接收者：用户本人 open_id（配置里省略接收者时用它）
    static let feishuDefaultReceiveID = "ou_16f6a5bbf67b40482fabaca6ccf74d5d"

    /// 结束速记的关键词（与 keywords.txt 里的结束词 @显示名 一致）
    static let endWords: Set<String> = ["结束", "发送", "完毕"]

    /// 速记最长秒数，超时自动结束并发送
    static let maxDictationSeconds = 60
}
