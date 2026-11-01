import SwiftUI
import UIKit

@main
struct MicProbeApp: App {
    @StateObject private var audio = AudioEngine()

    var body: some Scene {
        WindowGroup {
            ContentView(audio: audio)
                .onAppear {
                    // 前台常亮：采集期间不让屏幕休眠
                    UIApplication.shared.isIdleTimerDisabled = true
                    if Config.autoStartOnLaunch {
                        // 诊断/无人值守模式：启动 2 秒后自动开始采集
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            audio.start()
                        }
                    }
                }
        }
    }
}
