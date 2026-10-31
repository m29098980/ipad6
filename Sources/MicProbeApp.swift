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
                }
        }
    }
}
