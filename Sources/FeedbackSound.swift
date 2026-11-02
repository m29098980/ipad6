import AudioToolbox

/// 操作提示音：唤醒 / 发送成功时给用户明确反馈，
/// 即使没看屏幕（悬浮球在桌面、屏幕熄灭前）也能听到。
/// 用系统音效服务播放，不占用 App 的录音会话。
enum FeedbackSound {

    /// 唤醒成功：短促「叮」（Tink）
    static func wake() {
        AudioServicesPlaySystemSound(1054)
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
