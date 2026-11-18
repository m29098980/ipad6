import AudioToolbox
import AVFoundation

/// 操作提示音：唤醒 / 发送成功时给用户明确反馈，
/// 即使没看屏幕（悬浮球在桌面、屏幕熄灭前）也能听到。
/// 用系统音效服务播放，不占用 App 的录音会话。
enum FeedbackSound {

    /// 唤醒成功：短促「叮」（Tink）+ 语音播报「在」
    static func wake() {
        AudioServicesPlaySystemSound(1054)
        speakZai()
    }

    // 中文语音合成器（系统内置，无需打包音频文件）
    private static let synthesizer = AVSpeechSynthesizer()

    /// 用 iPad 内置中文语音说一声「在」，像 Siri 应答一样
    private static func speakZai() {
        let utterance = AVSpeechUtterance(string: "在")
        // 优先简体中文语音，找不到则退回任何中文语音
        utterance.voice = AVSpeechSynthesisVoice(language: "zh-CN")
            ?? AVSpeechSynthesisVoice(language: "zh-Hans")
            ?? AVSpeechSynthesisVoice(language: "zh")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 1.05
        utterance.pitchMultiplier = 1.15
        utterance.volume = 1.0
        // 走当前 playAndRecord 会话混音输出；先停掉上一段避免连读叠加
        synthesizer.stopSpeaking(at: .immediate)
        synthesizer.speak(utterance)
    }

    /// 速记结束 / 发送成功：系统「消息已发送」音
    static func success() {
        AudioServicesPlaySystemSound(1004)
    }

    /// 发送失败：低沉错误音
    static func failure() {
        AudioServicesPlaySystemSound(1053)
    }
}
