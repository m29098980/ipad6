import Foundation

/// 本地局域网语音转写：llama.cpp 服务器上的 Qwen3-ASR。
/// 接口：POST /v1/audio/transcriptions（multipart），响应 text 字段可能带
/// "language Chinese<asr_text>" 前缀，需清理。
enum RemoteASR {

    static let serverHost = "10.168.1.12:11530"
    static let endpoint = URL(string: "http://\(serverHost)/v1/audio/transcriptions")!
    static let model = "Qwen3-ASR"

    /// 检测局域网转写服务连通性；结果文案直接给日志展示
    static func check(completion: @escaping (String) -> Void) {
        var req = URLRequest(url: URL(string: "http://\(serverHost)/v1/models")!, timeoutInterval: 8)
        req.httpMethod = "GET"
        URLSession.shared.dataTask(with: req) { _, resp, err in
            if let err {
                completion("❌ 连不上转写服务：\(err.localizedDescription)。修复：iPad 设置 → 隐私与安全性 → 本地网络 → 打开 MicProbe；并确认 Wi-Fi 与电脑同一网段")
            } else if (resp as? HTTPURLResponse)?.statusCode == 200 {
                completion("✅ 转写服务连通，局域网转写可用")
            } else {
                completion("❌ 转写服务响应异常 http=\((resp as? HTTPURLResponse)?.statusCode ?? -1)")
            }
        }.resume()
    }

    /// 把 PCM 原声转成文字。completion 在任意线程回调：成功给清洗后的文本，失败给错误描述。
    static func transcribe(pcm: [Int16], sampleRate: Int = 16_000,
                           completion: @escaping (String) -> Void) {
        guard !pcm.isEmpty else {
            completion("没有录到音频")
            return
        }
        let wav = Feishu.makeWav(pcm: pcm, sampleRate: sampleRate)
        upload(wav: wav) { err, text in
            if let err {
                completion("转写失败：\(err)")
            } else {
                completion(clean(text ?? ""))
            }
        }
    }

    /// 清理模型输出：去掉 "language XX<asr_text>" 前缀与闭合标记、首尾空白
    static func clean(_ raw: String) -> String {
        var t = raw
        if let r = t.range(of: "<asr_text>") {
            t = String(t[r.upperBound...])
        }
        t = t.replacingOccurrences(of: "</asr_text>", with: "")
        // 有的输出带 "language Chinese" 之类残留前缀
        if t.hasPrefix("language ") {
            if let r = t.range(of: " ") {
                let rest = t[r.upperBound...]
                // "Chinese" 这种单词后面直接跟正文时再去一个词
                let words = rest.split(separator: " ", maxSplits: 1)
                t = words.count > 1 ? String(words[1]) : String(rest)
            }
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func upload(wav: Data, completion: @escaping (String?, String?) -> Void) {
        let boundary = "MicProbeASR\(Int(Date().timeIntervalSince1970 * 1000))"
        var req = URLRequest(url: endpoint, timeoutInterval: 60)
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        func field(_ n: String, _ v: String) {
            body.append(Data("--\(boundary)\r\n".utf8))
            body.append(Data("Content-Disposition: form-data; name=\"\(n)\"\r\n\r\n".utf8))
            body.append(Data(v.utf8))
            body.append(Data("\r\n".utf8))
        }
        field("model", model)
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"speech.wav\"\r\n".utf8))
        body.append(Data("Content-Type: application/octet-stream\r\n\r\n".utf8))
        body.append(wav)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        req.httpBody = body

        URLSession.shared.dataTask(with: req) { data, resp, err in
            if let err {
                completion("网络错误 \(err.localizedDescription)", nil)
                return
            }
            guard let data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                let http = (resp as? HTTPURLResponse)?.statusCode ?? -1
                completion("响应异常 http=\(http)", nil)
                return
            }
            if let text = obj["text"] as? String {
                completion(nil, text)
            } else if let msg = obj["error"] as? String ?? obj["message"] as? String {
                completion(msg, nil)
            } else {
                completion("响应缺少 text 字段", nil)
            }
        }.resume()
    }
}
