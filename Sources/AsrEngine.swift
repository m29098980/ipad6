import Foundation
import SherpaOnnx

/// 流式语音识别（速记转写）引擎。
/// 说「85号」唤醒后开始转写，说「结束 / 发送 / 完毕」取全文发送。
/// 模型：sherpa-onnx-streaming-zipformer-small-bilingual-zh-en（int8，中英双语，由 CI 下载到 Model/Asr/）
final class AsrEngine {

    private var recognizer: SherpaOnnxRecognizer?
    private(set) var ready = false

    /// 初始化；成功返回 nil，失败返回错误描述
    @discardableResult
    func setup() -> String? {
        guard !ready else { return nil }
        let bundle = Bundle.main

        func path(_ name: String, _ ext: String) throws -> String {
            guard let p = bundle.path(forResource: name, ofType: ext, inDirectory: "Model/Asr") else {
                throw NSError(domain: "AsrEngine", code: -1, userInfo: [
                    NSLocalizedDescriptionKey: "缺少模型文件 Model/Asr/\(name).\(ext)"
                ])
            }
            return p
        }

        do {
            NSLog("MPBOX: asr a) finding model files")
            let encoder = try path("encoder", "onnx")
            let decoder = try path("decoder", "onnx")
            let joiner  = try path("joiner",  "onnx")
            let tokens  = try path("tokens",  "txt")
            NSLog("MPBOX: asr b) model files found")

            var config = sherpaOnnxOnlineRecognizerConfig(
                featConfig: sherpaOnnxFeatureConfig(sampleRate: 16_000, featureDim: 80),
                modelConfig: sherpaOnnxOnlineModelConfig(
                    tokens: tokens,
                    transducer: sherpaOnnxOnlineTransducerModelConfig(
                        encoder: encoder,
                        decoder: decoder,
                        joiner: joiner
                    )
                ),
                enableEndpoint: false
            )
            NSLog("MPBOX: asr c) before recognizer init")
            self.recognizer = SherpaOnnxRecognizer(config: &config)
            self.ready = true
            NSLog("MPBOX: asr d) recognizer init ok")
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// 开始新的一段速记（清空内部解码状态）
    func restart() {
        recognizer?.reset()
    }

    /// 喂入一帧 16 kHz Int16 样本；必须在 processQueue 串行调用。返回当前累计识别文本。
    func feed(_ frame: [Int16]) -> String {
        guard let recognizer else { return "" }
        var samples = [Float]()
        samples.reserveCapacity(frame.count)
        for s in frame { samples.append(Float(s) / 32_768.0) }

        recognizer.acceptWaveform(samples: samples)
        while recognizer.isReady() {
            recognizer.decode()
        }
        return recognizer.getResult().text
    }
}
