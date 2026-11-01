import Foundation

/// 飞书群机器人通知。
/// 用户在飞书群里添加「自定义机器人」得到 Webhook 地址，粘贴到 App 界面的设置栏即可。
/// 协议：POST JSON {"msg_type":"text","content":{"text":"..."}}，返回 code == 0 表示成功。
enum Feishu {

    static let defaultsKey = "feishu_webhook"

    static var webhook: String {
        (UserDefaults.standard.string(forKey: defaultsKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func saveWebhook(_ raw: String) {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.standard.set(s, forKey: defaultsKey)
    }

    /// 发送文本消息。completion 在主线程回调：参数为 nil 表示成功，否则为错误描述。
    static func send(text: String, completion: @escaping (String?) -> Void) {
        let raw = webhook
        guard !raw.isEmpty, let endpoint = URL(string: raw),
              let host = endpoint.host, host.hasSuffix("feishu.cn") else {
            completion("Webhook 地址为空或不是飞书域名")
            return
        }

        var req = URLRequest(url: endpoint, timeoutInterval: 10)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload: [String: Any] = ["msg_type": "text",
                                      "content": ["text": text]]
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        URLSession.shared.dataTask(with: req) { data, resp, err in
            var result: String?
            if let err {
                result = "网络错误：\(err.localizedDescription)"
            } else if let http = resp as? HTTPURLResponse {
                let body = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                let code = body?["code"] as? Int ?? (http.statusCode == 200 ? 0 : -1)
                if code == 0 {
                    result = nil
                } else {
                    let msg = body?["msg"] as? String ?? ""
                    result = "飞书返回 code=\(code) \(msg)"
                }
            } else {
                result = "无响应"
            }
            DispatchQueue.main.async { completion(result) }
        }.resume()
    }
}
