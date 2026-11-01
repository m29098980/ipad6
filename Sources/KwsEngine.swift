import Foundation

/// 基于 sherpa-onnx KeywordSpotter 的离线唤醒词引擎
/// 模型：sherpa-onnx-kws-zipformer-wenetspeech-3.3M（int8，中文，约 10 MB）
/// 由编译脚本下载到 Bundle 的 Model/ 目录，仓库本身不存模型。
final class KwsEngine {

    private var spotter: SherpaOnnxKeywordSpotterWrapper?

    /// 初始化引擎；成功返回 nil，失败返回错误描述（不抛异常，方便 UI 直接打日志）
    @discardableResult
    func setup() -> String? {
        guard spotter == nil else { return nil }   // 已初始化过
        let bundle = Bundle.main

        func path(_ name: String, _ ext: String) throws -> String {
            guard let p = bundle.path(forResource: name, ofType: ext, subdirectory: "Model") else {
                throw NSError(domain: "KwsEngine", code: -1, userInfo: [
                    NSLocalizedDescriptionKey: "缺少模型文件 Model/\(name).\(ext)"
                ])
            }
            return p
        }

        do {
            let encoder = try path("encoder", "onnx")
            let decoder = try path("decoder", "onnx")
            let joiner  = try path("joiner",  "onnx")
            let tokens  = try path("tokens",  "txt")
            let kwFile  = try path("keywords", "txt")

            var config = sherpaOnnxKeywordSpotterConfig(
                featConfig: sherpaOnnxFeatureConfig(sampleRate: 16_000, featureDim: 80),
                modelConfig: sherpaOnnxOnlineModelConfig(
                    tokens: tokens,
                    transducer: sherpaOnnxOnlineTransducerModelConfig(
                        encoder: encoder,
                        decoder: decoder,
                        joiner: joiner
                    )
                ),
                keywordsFile: kwFile
            )
            self.spotter = SherpaOnnxKeywordSpotterWrapper(config: &config)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// 喂入一帧 16 kHz Int16 样本；命中唤醒词时返回关键词文本，否则返回 nil
    /// 必须在固定的串行队列上调用（AudioEngine.processQueue）
    func feed(_ frame: [Int16]) -> String? {
        guard let spotter else { return nil }
        var samples = [Float]()
        samples.reserveCapacity(frame.count)
        for s in frame { samples.append(Float(s) / 32_768.0) }

        spotter.acceptWaveform(samples: samples)

        var hit: String?
        while spotter.isReady() {
            spotter.decode()
            let kw = spotter.getResult().keyword
            if !kw.isEmpty {
                hit = kw
                spotter.reset()          // 命中后必须 reset，否则连续误报
            }
        }
        return hit
    }
}
