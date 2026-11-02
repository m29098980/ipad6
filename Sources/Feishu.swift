import Foundation
import AuthenticationServices

/// 飞书通知，支持两种配置（在设置栏粘贴后自动识别）：
/// 1. Webhook 模式：粘贴群自定义机器人的 https://open.feishu.cn/open-apis/bot/v2/hook/... 地址
/// 2. 应用模式：粘贴 "AppID,AppSecret[,接收者ID]"
///    - 接收者 ou_ 开头 = 机器人私聊发给该用户；oc_ 开头 = 发到该群
///    - 省略接收者时，发给 Config.feishuDefaultReceiveID
///    - 通过开放平台 API 发消息
/// 3. 用户身份（OAuth user_access_token）：
///    - 绑定后消息以「用户本人」名义发到与机器人的单聊（对方的事件回调才会受理）
///    - 机器人自己发的消息不会推给它自己的事件订阅，所以必须用用户身份
enum Feishu {

    static let defaultsKey = "feishu_webhook"
    private static let tokenKey = "feishu_tenant_token"
    private static let tokenExpKey = "feishu_token_expire"

    // ---- 用户身份（OAuth）存储键 ----
    private static let userTokenKey = "feishu_user_token"
    private static let userTokenExpKey = "feishu_user_token_exp"
    private static let userRefreshKey = "feishu_user_refresh"
    private static let userRefreshExpKey = "feishu_user_refresh_exp"

    /// OAuth 重定向地址（需与开放平台「安全设置 → 重定向 URL」完全一致）
    static let redirectURI = "micprobe://auth"
    /// 授权 scope：发消息 + 离线访问（换取 refresh_token 长期续期）
    static let oauthScopes = "im:message offline_access"

    /// 是否已绑定用户身份（有未过期的 refresh_token 即视为已绑定）
    static var userTokenBound: Bool {
        let ud = UserDefaults.standard
        let refresh = ud.string(forKey: userRefreshKey) ?? ""
        let exp = ud.double(forKey: userRefreshExpKey)
        return !refresh.isEmpty && Date().timeIntervalSince1970 < exp
    }

    /// 解绑用户身份，恢复机器人名义发送
    static func unbindUser() {
        let ud = UserDefaults.standard
        for k in [userTokenKey, userTokenExpKey, userRefreshKey, userRefreshExpKey] {
            ud.removeObject(forKey: k)
        }
    }

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
    /// 已绑定用户身份 → 以用户本人名义发到与机器人的单聊；
    /// 未绑定 → 按配置走机器人/webhook。
    static func send(text: String, completion: @escaping (String?) -> Void) {
        if userTokenBound {
            sendAsUser(text: text, completion: completion)
            return
        }
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

    // MARK: - 用户身份（OAuth user_access_token）

    private static var authSession: ASWebAuthenticationSession?
    /// 持有锚点对象，防止授权期间被释放
    private static var authAnchor: AuthAnchor?

    /// 授权页展示锚点：返回 keyWindow 作为弹出容器
    private final class AuthAnchor: NSObject, ASWebAuthenticationPresentationContextProviding {
        weak var window: UIWindow?
        init(window: UIWindow) { self.window = window }
        func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
            window ?? ASPresentationAnchor()
        }
    }

    /// 打开飞书授权页，引导用户登录并授权，回调后自动换取并保存 token。
    static func startUserAuth(log: @escaping (String) -> Void) {
        guard let cfg = parseAppConfig(webhook) else {
            log("绑定身份前请先在下方粘贴 AppID,AppSecret")
            return
        }
        var comps = URLComponents(string: "https://accounts.feishu.cn/open-apis/authen/v1/authorize")!
        let state = "micprobe\(Int(Date().timeIntervalSince1970))"
        comps.queryItems = [
            URLQueryItem(name: "client_id", value: cfg.appID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: oauthScopes),
            URLQueryItem(name: "state", value: state)
        ]
        guard let url = comps.url else {
            log("构造授权 URL 失败")
            return
        }
        log("正在打开飞书授权页…请登录并点「同意授权」")
        let session = ASWebAuthenticationSession(url: url, callbackURLScheme: "micprobe") { callbackURL, error in
            if let error {
                log("授权未完成：\(error.localizedDescription)")
                return
            }
            guard let cb = callbackURL,
                  let cp = URLComponents(url: cb, resolvingAgainstBaseURL: false),
                  let code = cp.queryItems?.first(where: { $0.name == "code" })?.value else {
                log("授权回调缺少 code：\(callbackURL?.absoluteString.prefix(120) ?? "nil")")
                return
            }
            if cp.queryItems?.first(where: { $0.name == "error" })?.value != nil {
                log("用户拒绝了授权")
                return
            }
            exchangeCode(code: code, appID: cfg.appID, secret: cfg.secret, log: log)
        }
        // presentationContextProvider 需要自定义对象实现协议（UIKit 类型未隐式实现）
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let win = scene.keyWindow {
            let anchor = AuthAnchor(window: win)
            authAnchor = anchor
            session.presentationContextProvider = anchor
        }
        authSession = session
        session.start()
    }

    /// 授权码换 user_access_token + refresh_token（v2 接口，JSON 请求体）
    private static func exchangeCode(code: String, appID: String, secret: String,
                                     log: @escaping (String) -> Void) {
        tokenRequest(body: ["grant_type": "authorization_code",
                            "client_id": appID,
                            "client_secret": secret,
                            "code": code,
                            "redirect_uri": redirectURI]) { obj, errMsg in
            if let obj {
                storeTokens(obj)
                log("已绑定你的飞书身份 ✓ 之后消息以你本人名义发送")
            } else {
                log("换取用户 token 失败：\(errMsg ?? "未知错误")（请检查开放平台：重定向 URL 是否已添加 \(redirectURI)；权限是否已开通 im:message、offline_access 并发布版本）")
            }
        }
    }

    /// 确保拿到有效的 user_access_token（过期则用 refresh_token 续期）
    private static func ensureUserToken(appID: String, secret: String,
                                        completion: @escaping (String?, String?) -> Void) {
        let ud = UserDefaults.standard
        let cached = ud.string(forKey: userTokenKey) ?? ""
        if !cached.isEmpty, Date().timeIntervalSince1970 < ud.double(forKey: userTokenExpKey) {
            completion(nil, cached)
            return
        }
        let refresh = ud.string(forKey: userRefreshKey) ?? ""
        guard !refresh.isEmpty, Date().timeIntervalSince1970 < ud.double(forKey: userRefreshExpKey) else {
            completion("用户授权已过期，请重新绑定身份", nil)
            return
        }
        tokenRequest(body: ["grant_type": "refresh_token",
                            "client_id": appID,
                            "client_secret": secret,
                            "refresh_token": refresh]) { obj, errMsg in
            if let obj {
                storeTokens(obj)
                completion(nil, obj["access_token"] as? String)
            } else {
                completion("刷新用户 token 失败：\(errMsg ?? "未知错误")", nil)
            }
        }
    }

    /// 以用户本人名义发文本到与机器人的单聊（chat_id 固定，用户是会话成员）
    static func sendAsUser(text: String, completion: @escaping (String?) -> Void) {
        guard let cfg = parseAppConfig(webhook) else {
            completion("用户身份发送需要应用模式配置（AppID,AppSecret）")
            return
        }
        ensureUserToken(appID: cfg.appID, secret: cfg.secret) { err, token in
            if let err { completion("以你的身份发送失败：\(err)"); return }
            guard let token else { completion("以你的身份发送失败：无 token"); return }
            var comps = URLComponents(string: "https://open.feishu.cn/open-apis/im/v1/messages")!
            comps.queryItems = [URLQueryItem(name: "receive_id_type", value: "chat_id")]
            guard let url = comps.url else {
                completion("构造消息 URL 失败")
                return
            }
            let contentJSON: String
            if let d = try? JSONSerialization.data(withJSONObject: ["text": text]),
               let s = String(data: d, encoding: .utf8) {
                contentJSON = s
            } else {
                contentJSON = "{\"text\":\"\(text)\"}"
            }
            postJSON(url: url,
                     body: ["receive_id": Config.feishuP2PChatID,
                            "msg_type": "text",
                            "content": contentJSON],
                     headers: ["Authorization": "Bearer \(token)"]) { data, resp, err in
                if let e = judgeCode(data: data, resp: resp, err: err) {
                    completion("以你的身份发送失败：\(e)")
                } else {
                    completion(nil)
                }
            }
        }
    }

    /// 调用 v2 oauth/token 接口。completion 参数：成功给响应字典，失败给错误描述。
    private static func tokenRequest(body: [String: Any],
                                     completion: @escaping ([String: Any]?, String?) -> Void) {
        guard let url = URL(string: "https://open.feishu.cn/open-apis/authen/v2/oauth/token") else {
            completion(nil, "URL 错误")
            return
        }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.httpMethod = "POST"
        req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        URLSession.shared.dataTask(with: req) { data, _, err in
            if let err {
                completion(nil, "网络错误 \(err.localizedDescription)")
                return
            }
            guard let data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                completion(nil, "响应解析失败")
                return
            }
            if let code = obj["code"] as? Int, code != 0 {
                completion(nil, "code=\(code) \(obj["msg"] as? String ?? "")")
                return
            }
            guard obj["access_token"] is String else {
                completion(nil, "缺少 access_token：\(obj["msg"] as? String ?? "")")
                return
            }
            completion(obj, nil)
        }.resume()
    }

    /// 保存 access_token / refresh_token 及到期时间（提前 5 分钟/1 小时判过期）
    private static func storeTokens(_ obj: [String: Any]) {
        let ud = UserDefaults.standard
        let now = Date().timeIntervalSince1970
        ud.set(obj["access_token"] as? String ?? "", forKey: userTokenKey)
        ud.set(now + (obj["expires_in"] as? Double ?? 7200) - 300, forKey: userTokenExpKey)
        if let rt = obj["refresh_token"] as? String, !rt.isEmpty {
            ud.set(rt, forKey: userRefreshKey)
            ud.set(now + (obj["refresh_token_expires_in"] as? Double ?? 604_800) - 3600,
                   forKey: userRefreshExpKey)
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

    // MARK: - 语音文件上传（应用模式）

    /// 把 PCM 原声打包成 WAV，上传到飞书后以文件消息发给接收者。
    /// 仅支持应用模式（AppID,AppSecret）；webhook 模式返回错误。
    static func sendAudio(pcm: [Int16], sampleRate: Int = 16_000,
                          completion: @escaping (String?) -> Void) {
        let raw = webhook
        guard let cfg = parseAppConfig(raw) else {
            completion("发语音需要应用模式配置（AppID,AppSecret）")
            return
        }
        guard !pcm.isEmpty else {
            completion("没有录到音频")
            return
        }
        let wav = makeWav(pcm: pcm, sampleRate: sampleRate)
        getToken(appID: cfg.appID, secret: cfg.secret) { tokenErr, token in
            if let tokenErr { completion(tokenErr); return }
            guard let token else { completion("获取 tenant_access_token 失败"); return }
            let fmt = DateFormatter()
            fmt.dateFormat = "HHmmss"
            let name = "MicProbe-速记-\(fmt.string(from: Date())).wav"
            uploadFile(token: token, wav: wav, name: name) { upErr, fileKey in
                if let upErr { completion(upErr); return }
                guard let fileKey else { completion("上传成功但未返回 file_key"); return }
                var comps = URLComponents(string: "https://open.feishu.cn/open-apis/im/v1/messages")!
                comps.queryItems = [URLQueryItem(name: "receive_id_type", value: "open_id")]
                guard let url = comps.url else {
                    completion("构造消息 URL 失败")
                    return
                }
                // content 必须是「JSON 字符串」，用 JSONSerialization 生成，杜绝手拼引号错误
                guard let cd = try? JSONSerialization.data(withJSONObject: ["file_key": fileKey]),
                      let content = String(data: cd, encoding: .utf8) else {
                    completion("构造 file content 失败")
                    return
                }
                postJSON(url: url,
                         body: ["receive_id": cfg.receive, "msg_type": "file", "content": content],
                         headers: ["Authorization": "Bearer \(token)"]) { data, resp, err in
                    completion(judgeCode(data: data, resp: resp, err: err))
                }
            }
        }
    }

    private static func uploadFile(token: String, wav: Data, name: String,
                                   completion: @escaping (String?, String?) -> Void) {        let boundary = "MicProbe\(Int(Date().timeIntervalSince1970 * 1000))"
        guard let url = URL(string: "https://open.feishu.cn/open-apis/im/v1/files") else {
            completion("URL 错误", nil)
            return
        }
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        func field(_ n: String, _ v: String) {
            body.append(Data("--\(boundary)\r\n".utf8))
            body.append(Data("Content-Disposition: form-data; name=\"\(n)\"\r\n\r\n".utf8))
            body.append(Data(v.utf8))
            body.append(Data("\r\n".utf8))
        }
        field("file_type", "stream")
        field("file_name", name)
        field("duration", "0")
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"\(name)\"\r\n".utf8))
        body.append(Data("Content-Type: application/octet-stream\r\n\r\n".utf8))
        body.append(wav)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        req.httpBody = body

        URLSession.shared.dataTask(with: req) { data, resp, err in
            if let err {
                completion("上传网络错误：\(err.localizedDescription)", nil)
                return
            }
            guard let data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (obj["code"] as? Int ?? -1) == 0,
                  let fileKey = (obj["data"] as? [String: Any])?["file_key"] as? String else {
                let msg = (data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })?["msg"] as? String ?? ""
                completion("上传失败 \(msg)", nil)
                return
            }
            completion(nil, fileKey)
        }.resume()
    }

    /// 发送飞书「语音消息」（聊天气泡样式，可长按转文字）。
    /// 要求 ogg 为 Ogg Opus 格式（飞书语音消息只收 opus）。
    /// 仅支持应用模式；webhook 模式不支持语音消息。
    static func sendVoice(ogg: Data, durationMS: Int,
                          completion: @escaping (String?) -> Void) {
        let raw = webhook
        guard let cfg = parseAppConfig(raw) else {
            completion("发语音消息需要应用模式配置（AppID,AppSecret）")
            return
        }
        guard !ogg.isEmpty else {
            completion("语音数据为空")
            return
        }
        getToken(appID: cfg.appID, secret: cfg.secret) { tokenErr, token in
            if let tokenErr { completion(tokenErr); return }
            guard let token else { completion("获取 tenant_access_token 失败"); return }
            let fmt = DateFormatter()
            fmt.dateFormat = "HHmmss"
            let name = "MicProbe-速记-\(fmt.string(from: Date())).opus"
            uploadVoice(token: token, opus: ogg, name: name, durationMS: durationMS) { upErr, fileKey in
                if let upErr { completion(upErr); return }
                guard let fileKey else { completion("上传成功但未返回 file_key"); return }
                var comps = URLComponents(string: "https://open.feishu.cn/open-apis/im/v1/messages")!
                comps.queryItems = [URLQueryItem(name: "receive_id_type", value: "open_id")]
                guard let url = comps.url else {
                    completion("构造消息 URL 失败")
                    return
                }
                guard let cd = try? JSONSerialization.data(withJSONObject: ["file_key": fileKey]),
                      let content = String(data: cd, encoding: .utf8) else {
                    completion("构造 audio content 失败")
                    return
                }
                postJSON(url: url,
                         body: ["receive_id": cfg.receive, "msg_type": "audio", "content": content],
                         headers: ["Authorization": "Bearer \(token)"]) { data, resp, err in
                    completion(judgeCode(data: data, resp: resp, err: err))
                }
            }
        }
    }

    /// 上传语音文件（file_type=opus）
    private static func uploadVoice(token: String, opus: Data, name: String, durationMS: Int,
                                    completion: @escaping (String?, String?) -> Void) {
        let boundary = "MicProbeOpus\(Int(Date().timeIntervalSince1970 * 1000))"
        guard let url = URL(string: "https://open.feishu.cn/open-apis/im/v1/files") else {
            completion("URL 错误", nil)
            return
        }
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        func field(_ n: String, _ v: String) {
            body.append(Data("--\(boundary)\r\n".utf8))
            body.append(Data("Content-Disposition: form-data; name=\"\(n)\"\r\n\r\n".utf8))
            body.append(Data(v.utf8))
            body.append(Data("\r\n".utf8))
        }
        field("file_type", "opus")
        field("file_name", name)
        field("duration", String(durationMS))   // 语音时长（毫秒）
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"\(name)\"\r\n".utf8))
        body.append(Data("Content-Type: application/opus\r\n\r\n".utf8))
        body.append(opus)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        req.httpBody = body

        URLSession.shared.dataTask(with: req) { data, resp, err in
            if let err {
                completion("上传网络错误：\(err.localizedDescription)", nil)
                return
            }
            guard let data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (obj["code"] as? Int ?? -1) == 0,
                  let fileKey = (obj["data"] as? [String: Any])?["file_key"] as? String else {
                let msg = (data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })?["msg"] as? String ?? ""
                completion("上传失败 \(msg)", nil)
                return
            }
            completion(nil, fileKey)
        }.resume()
    }

    /// PCM16 单声道 → WAV 容器
    static func makeWav(pcm: [Int16], sampleRate: Int) -> Data {
        var d = Data()
        let byteCount = pcm.count * 2
        func le32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func le16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append(Data("RIFF".utf8)); le32(UInt32(36 + byteCount)); d.append(Data("WAVE".utf8))
        d.append(Data("fmt ".utf8)); le32(16); le16(1); le16(1)
        le32(UInt32(sampleRate)); le32(UInt32(sampleRate * 2)); le16(2); le16(16)
        d.append(Data("data".utf8)); le32(UInt32(byteCount))
        pcm.withUnsafeBufferPointer { buf in
            d.append(contentsOf: UnsafeRawBufferPointer(buf))
        }
        return d
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
