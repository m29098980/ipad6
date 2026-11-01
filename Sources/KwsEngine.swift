import Foundation
import SherpaOnnx

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
            guard let p = bundle.path(forResource: name, ofType: ext, inDirectory: "Model") else {
                throw NSError(domain: "KwsEngine", code: -1, userInfo: [
                    NSLocalizedDescriptionKey: "缺少模型文件 Model/\(name).\(ext)"
                ])
            }
            return p
        }

        do {
            NSLog("MPBOX: kws a) finding model files")
            let encoder = try path("encoder", "onnx")
            let decoder = try path("decoder", "onnx")
            let joiner  = try path("joiner",  "onnx")
            let tokens  = try path("tokens",  "txt")
            let kwFile  = try path("keywords", "txt")
            NSLog("MPBOX: kws b) model files found")

            // 关键防御：sherpa-onnx 遇到词表里不存在的 token 会直接 LOG(FATAL) 终止进程。
            // 这里先把 keywords.txt 里每个 token 与 tokens.txt 比对，只保留合法行，写到临时文件。
            let tokensText = try String(contentsOfFile: tokens, encoding: .utf8)
            NSLog("MPBOX: kws c) tokens loaded \(tokensText.count) chars")
            let vocab = Set(tokensText.split(separator: "\n").map { line in
                line.split(separator: " ", omittingEmptySubsequences: true).first.map(String.init) ?? String(line)
            })
            NSLog("MPBOX: kws d) vocab \(vocab.count) entries")

            let kwText = try String(contentsOfFile: kwFile, encoding: .utf8)
            var kept: [String] = []
            var dropped: [String] = []
            for raw in kwText.split(separator: "\n") {
                let line = raw.trimmingCharacters(in: .whitespaces)
                guard !line.isEmpty, line.contains("@") else { continue }
                let tokenPart = line[..<line.range(of: "@")!.lowerBound]
                let toks = tokenPart.split(separator: " ").map(String.init)
                if !toks.isEmpty && toks.allSatisfy(vocab.contains) {
                    kept.append(line)
                } else {
                    dropped.append(line)
                }
            }
            guard !kept.isEmpty else {
                throw NSError(domain: "KwsEngine", code: -2, userInfo: [
                    NSLocalizedDescriptionKey: "关键词全部不在模型词表中（共丢弃 \(dropped.count) 行）"
                ])
            }

            let filtered = kept.joined(separator: "\n") + "\n"
            NSLog("MPBOX: kws e) keywords kept \(kept.count) dropped \(dropped.count)")
            let filteredPath = NSTemporaryDirectory() + "keywords_filtered.txt"
            try filtered.write(toFile: filteredPath, atomically: true, encoding: .utf8)

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
                keywordsFile: filteredPath
            )
            NSLog("MPBOX: kws f) before wrapper init")
            self.spotter = SherpaOnnxKeywordSpotterWrapper(config: &config)
            NSLog("MPBOX: kws g) wrapper init ok")
            if !dropped.isEmpty {
                // 通过静态变量把丢弃信息带回（简单做法：写到文件，AudioEngine 可读）
                try (dropped.joined(separator: "\n")).write(
                    toFile: NSTemporaryDirectory() + "keywords_dropped.txt",
                    atomically: true, encoding: .utf8)
            }
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
