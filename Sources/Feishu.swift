import Foundation

/// 飞书通知，支持两种配置（在设置栏粘贴后自动识别）：
/// 1. Webhook 模式：粘贴群自定义机器人的 https://open.feishu.cn/open-apis/bot/v2/hook/... 地址
/// 2. 应用模式：粘贴 "AppID,AppSecret[,接收者ID]"
///    - 接收者 ou_ 开头 = 机器人私聊发给该用户；oc_ 开头 = 发到该群
///    - 省略接收者时，发给 Config.feishuDefaultReceiveID
///    - 通过开放平台 API 以机器人本人名义发消息
enum Feishu {

    static let defaultsKey = "feishu_webhook"
    private static let tokenKey = "feishu_tenant_token"
    private static let tokenExpKey = "feishu_token_expire"

    static var webhook: String {
        (UserDefaults.standard.string(forKey: defaultsKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func saveWebhook(_ raw: String) {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.standard.set(s, forKey: defaultsKey)
    }

    // MARK: - 发送入口

    /// 发送文本消息。completion 在主线程回调：参数为 nil 表示成功，否则为错误描述。
    static func send(text: String, completion: @escaping (String?) -> Void) {
        let raw = webhook
        if raw.contains("open-apis/bot/v2/hook") {
            sendWebhook(raw, text: text, completion: completion)
        } else if raw.lowercased().hasPrefix("cli_") {
            sendViaApp(raw, text: text, completion: completion)
        } else if raw.isEmpty {
            completion("配置为空：请粘贴 Webhook 地址或 AppID,AppSecret")
        } else {
            completion("无法识别的配置格式（应为 Webhook 地址或 cli_ 开头的 AppID,AppSecret）")
        }
    }

    // MARK: - Webhook 模式

    private static func sendWebhook(_ raw: String, text: String,
                                    completion: @escaping (String?) -> Void) {
        guard let endpoint = URL(string: raw),
              let host = endpoint.host, host.hasSuffix("feishu.cn") else {
            completion("Webhook 地址不是飞书域名")
            return
        }
        postJSON(url: endpoint, body: ["msg_type": "text", "content": ["text": text]],
                 headers: [:]) { data, resp, err in
            completion(judgeCode(data: data, resp: resp, err: err))
        }
    }

    // MARK: - 应用模式

    private static func parseAppConfig(_ raw: String) -> (appID: String, secret: String, receive: String)? {
        let parts = raw.split(whereSeparator: { ",，| \t\n".contains($0) }).map(String.init)
        guard parts.count >= 2, parts[0].lowercased().hasPrefix("cli_") else { return nil }
        let receive = parts.count >= 3 ? parts[2] : Config.feishuDefaultReceiveID
        return (parts[0], parts[1], receive)
    }

    private static func sendViaApp(_ raw: String, text: String,
                                   completion: @escaping (String?) -> Void) {
        guard let cfg = parseAppConfig(raw) else {
            completion("应用配置格式应为：AppID,AppSecret[,ou_xxx 或 oc_xxx]")
            return
        }
        getToken(appID: cfg.appID, secret: cfg.secret) { tokenErr, token in
            if let tokenErr { completion(tokenErr); return }
            guard let token else { completion("获取 tenant_access_token 失败"); return }

            let idType = cfg.receive.hasPrefix("oc_") ? "chat_id" : "open_id"
            var comps = URLComponents(string: "https://open.feishu.cn/open-apis/im/v1/messages")!
            comps.queryItems = [URLQueryItem(name: "receive_id_type", value: idType)]
            guard let url = comps.url else {
                completion("构造消息 URL 失败")
                return
            }
            // content 字段要求是「JSON 字符串」，需先把文本转成 JSON 字面量
            let contentJSON: String
            if let d = try? JSONSerialization.data(withJSONObject: ["text": text]),
               let s = String(data: d, encoding: .utf8) {
                contentJSON = s
            } else {
                contentJSON = "{\"text\":\"\(text)\"}"
            }
            postJSON(url: url,
                     body: ["receive_id": cfg.receive, "msg_type": "text", "content": contentJSON],
                     headers: ["Authorization": "Bearer \(token)"]) { data, resp, err in
                completion(judgeCode(data: data, resp: resp, err: err))
            }
        }
    }

    /// 获取 tenant_access_token（缓存约 2 小时）
    private static func getToken(appID: String, secret: String,
                                 completion: @escaping (String?, String?) -> Void) {
        let ud = UserDefaults.standard
        let cached = ud.string(forKey: tokenKey) ?? ""
        let exp = ud.double(forKey: tokenExpKey)
        if !cached.isEmpty, Date().timeIntervalSince1970 < exp {
            completion(nil, cached)
            return
        }
        let url = URL(string: "https://open.feishu.cn/open-apis/auth/v3/tenant_access_token/internal")!
        postJSON(url: url, body: ["app_id": appID, "app_secret": secret], headers: [:]) { data, resp, err in
            if let err {
                completion("获取 token 网络错误：\(err.localizedDescription)", nil)
                return
            }
            guard let data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let token = obj["tenant_access_token"] as? String,
                  (obj["code"] as? Int ?? -1) == 0 else {
                let msg = (data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })?["msg"] as? String ?? ""
                completion("获取 token 失败 \(msg)", nil)
                return
            }
            let expire = obj["expire"] as? Double ?? 7200
            ud.set(token, forKey: tokenKey)
            ud.set(Date().timeIntervalSince1970 + expire - 120, forKey: tokenExpKey)
            completion(nil, token)
        }
    }

    // MARK: - 公共工具

    private static func postJSON(url: URL, body: [String: Any], headers: [String: String],
                                 completion: @escaping (Data?, URLResponse?, Error?) -> Void) {
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        URLSession.shared.dataTask(with: req, completionHandler: completion).resume()
    }

    /// 判定飞书返回：code == 0 成功
    private static func judgeCode(data: Data?, resp: URLResponse?, err: Error?) -> String? {
        if let err { return "网络错误：\(err.localizedDescription)" }
        guard let http = resp as? HTTPURLResponse else { return "无响应" }
        let body = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let code = body?["code"] as? Int ?? (http.statusCode == 200 ? 0 : -1)
        if code == 0 { return nil }
        let msg = body?["msg"] as? String ?? ""
        return "飞书返回 code=\(code) \(msg)"
    }
}
