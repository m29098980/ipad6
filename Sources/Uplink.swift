import Foundation

/// 把 16 kHz / 单声道 / Int16 小端的原始 PCM 以 HTTP POST 发到服务端。
///
/// 服务端按 Content-Type: application/octet-stream 接收裸流，
/// 采样率与声道数在请求头里说明，便于服务端校验。
///
/// 设计上刻意做成「丢帧优于堆积」：同一时刻只允许一个请求在飞，
/// 网络慢的时候直接丢弃新块，避免内存无限增长把 App 撑爆。
final class Uplink {

    private let url: URL
    private let session: URLSession
    private let stateQueue = DispatchQueue(label: "com.jychan.micprobe.uplink")
    private var inflight = false

    init?(urlString: String) {
        guard let url = URL(string: urlString), url.scheme != nil else { return nil }
        self.url = url
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 8
        cfg.waitsForConnectivity = false
        self.session = URLSession(configuration: cfg)
    }

    func send(pcm: [Int16]) {
        var shouldSend = false
        stateQueue.sync {
            if !inflight {
                inflight = true
                shouldSend = true
            }
        }
        guard shouldSend else { return }

        let body = pcm.withUnsafeBufferPointer { Data(buffer: $0) }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue("\(Int(Config.sampleRate))", forHTTPHeaderField: "X-Sample-Rate")
        request.setValue("1", forHTTPHeaderField: "X-Channels")
        request.setValue("s16le", forHTTPHeaderField: "X-Sample-Format")
        request.httpBody = body

        session.dataTask(with: request) { [weak self] _, _, _ in
            guard let self else { return }
            self.stateQueue.async { self.inflight = false }
        }.resume()
    }
}
