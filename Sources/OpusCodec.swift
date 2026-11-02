import AudioToolbox
import Foundation

/// PCM(16 kHz Int16 单声道) → Opus 编码（iOS 13+ AudioConverter）→ Ogg Opus 容器。
/// 飞书「语音消息」（msg_type=audio）要求上传 opus 格式的文件，
/// 所以录音要先转成 .opus 才能以语音气泡形式出现在聊天里。
enum OpusCodec {

    /// kAudioConverterErr_RequiresMoreInputData（'insz'）在 Swift 中未导出，用字面值
    private static let requiresMoreInputData = OSStatus(0x696E_737A)

    /// 异步编码：成功回调 Ogg Opus 数据；失败回调错误描述
    static func encode(pcm: [Int16], sampleRate: Int,
                       completion: @escaping (Data?, String?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let data = try encodeSync(pcm: pcm, sampleRate: sampleRate)
                DispatchQueue.main.async { completion(data, nil) }
            } catch {
                DispatchQueue.main.async { completion(nil, error.localizedDescription) }
            }
        }
    }

    // MARK: - 编码主流程

    static func encodeSync(pcm: [Int16], sampleRate: Int) throws -> Data {
        guard !pcm.isEmpty else { throw CodecError("没有音频数据") }

        // 输入：16 kHz / Int16 / 单声道 PCM
        var input = AudioStreamBasicDescription(
            mSampleRate: Double(sampleRate),
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2,
            mFramesPerPacket: 1,
            mBytesPerFrame: 2,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 16,
            mReserved: 0)

        // 输出：Opus（内部 48 kHz，每包 960 帧 = 20 ms）
        var output = AudioStreamBasicDescription(
            mSampleRate: 48_000,
            mFormatID: kAudioFormatOpus,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: 960,
            mBytesPerFrame: 0,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 0,
            mReserved: 0)

        var converter: AudioConverterRef?
        let st = AudioConverterNew(&input, &output, &converter)
        guard st == noErr, let converter else {
            throw CodecError("创建 Opus 编码器失败（OSStatus=\(st)，设备可能不支持 Opus 编码）")
        }
        defer { AudioConverterDispose(converter) }

        // 语音码率 24 kbps
        var bitrate = UInt32(24_000)
        AudioConverterSetProperty(converter, kAudioConverterEncodeBitRate,
                                  UInt32(MemoryLayout<UInt32>.size), &bitrate)

        // 输入上下文：C 回调里按需取 PCM
        let ctx = InputContext(samples: pcm)
        let ctxPtr = Unmanaged.passUnretained(ctx).toOpaque()

        var packets: [Data] = []

        // 输出暂存区：一次最多收 64 个 opus 包（单包上限 1275 B → 128 KB 足够）
        let maxPacketsPerCall = 64
        let outBufSize = 131_072
        let outData = UnsafeMutableRawPointer.allocate(byteCount: outBufSize, alignment: 16)
        defer { outData.deallocate() }
        // outPacketDescription（FillComplexBuffer 参数是单指针数组；回调里才是双指针）
        let packetDescs = UnsafeMutablePointer<AudioStreamPacketDescription>
            .allocate(capacity: maxPacketsPerCall)
        defer { packetDescs.deallocate() }

        let abl = AudioBufferList.allocate(maximumBuffers: 1)
        defer { abl.unsafeMutablePointer.deallocate() }
        abl[0].mNumberChannels = 1
        abl[0].mData = outData

        while true {
            abl[0].mDataByteSize = UInt32(outBufSize)
            var outPacketCount = UInt32(maxPacketsPerCall)

            let fill = AudioConverterFillComplexBuffer(converter,
                                                       fillInput,
                                                       ctxPtr,
                                                       &outPacketCount,
                                                       abl.unsafeMutablePointer,
                                                       packetDescs)
            if fill == noErr || fill == requiresMoreInputData {
                let got = Int(outPacketCount)
                let produced = abl[0].mDataByteSize
                if got > 0, produced > 0 {
                    let chunk = Data(bytes: outData, count: Int(produced))
                    for i in 0..<got {
                        let d = packetDescs[i]
                        let start = Int(d.mStartOffset)
                        let size = Int(d.mDataByteSize)
                        guard start >= 0, size > 0, start + size <= chunk.count else { continue }
                        packets.append(chunk.subdata(in: start..<(start + size)))
                    }
                }
                if fill == requiresMoreInputData { break }  // 输入耗尽
                if got == 0 { break }
            } else {
                throw CodecError("Opus 编码失败（OSStatus=\(fill)）")
            }
        }

        guard !packets.isEmpty else { throw CodecError("Opus 编码输出为空") }
        return OggMuxer.mux(packets: packets, inputSampleRate: sampleRate)
    }

    /// 输入供给回调：把剩余 PCM 逐段交给 AudioConverter
    /// （签名即 AudioConverterComplexInputDataProc：第 4 参是「指针的指针」数组）
    private static let fillInput: AudioConverterComplexInputDataProc = { _, ioNumPackets, ioData, _, inUserData in
        let ctx = Unmanaged<InputContext>.fromOpaque(inUserData!).takeUnretainedValue()
        let remain = ctx.samples.count - ctx.pos
        guard remain > 0 else {
            ioNumPackets.pointee = 0      // 供给完毕 → converter 返回 RequiresMoreInputData
            return noErr
        }
        let n = min(remain, Int(ioNumPackets.pointee))
        ioNumPackets.pointee = UInt32(n)
        // 数组内存由 ctx 稳定持有（COW 未触发），converter 在本轮 FillComplexBuffer 内消费
        ctx.samples.withUnsafeBufferPointer { src in
            ioData.pointee.mNumberBuffers = 1
            ioData.pointee.mBuffers.mNumberChannels = 1
            ioData.pointee.mBuffers.mDataByteSize = UInt32(n * 2)
            ioData.pointee.mBuffers.mData =
                UnsafeMutableRawPointer(mutating: UnsafeRawPointer(src.baseAddress!.advanced(by: ctx.pos)))
        }
        ctx.pos += n
        return noErr
    }

    private final class InputContext {
        let samples: [Int16]
        var pos = 0
        init(samples: [Int16]) { self.samples = samples }
    }

    struct CodecError: Error, CustomStringConvertible {
        let message: String
        init(_ m: String) { message = m }
        var description: String { message }
    }
}

// MARK: - Ogg Opus 封装器（纯 Swift，RFC 7845）

enum OggMuxer {

    /// 把裸 Opus 包封装成标准 .opus（Ogg Opus）文件
    static func mux(packets: [Data], inputSampleRate: Int, preSkip: UInt16 = 312) -> Data {
        var out = Data()
        let serial: UInt32 = 0x4D696350   // "MicP"
        var seq: UInt32 = 0

        // 页 1：OpusHead（BOS 页）
        var head = Data("OpusHead".utf8)
        head.append(1)                                        // version
        head.append(1)                                        // channels
        head.append(contentsOf: withUnsafeBytes(of: preSkip.littleEndian) { Array($0) })
        head.append(contentsOf: withUnsafeBytes(of: UInt32(inputSampleRate).littleEndian) { Array($0) })
        head.append(contentsOf: [0, 0])                       // output gain
        head.append(0)                                        // mapping family
        out += page(packets: [head], headerType: 0x02, granule: 0, serial: serial, seq: seq)
        seq += 1

        // 页 2：OpusTags
        var tags = Data("OpusTags".utf8)
        tags.append(6)                                        // vendor 长度
        tags.append(Data("MicPrb".utf8))
        tags.append(contentsOf: [0, 0, 0, 0])                 // 无注释
        out += page(packets: [tags], headerType: 0x00, granule: 0, serial: serial, seq: seq)
        seq += 1

        // 音频页：granule 按 48 kHz 累计（每包 960 帧 = 20 ms）
        var granule: UInt64 = 0
        var pending: [Data] = []
        for p in packets {
            pending.append(p)
            granule += 960
            if pending.count >= 40 {
                out += page(packets: pending, headerType: 0x00, granule: granule, serial: serial, seq: seq)
                seq += 1
                pending = []
            }
        }
        if !pending.isEmpty {
            out += page(packets: pending, headerType: 0x04, granule: granule, serial: serial, seq: seq) // EOS
        }
        return out
    }

    /// 组一个 Ogg 页（payload 拆 255 字节段，末段为实际剩余长度）
    private static func page(packets: [Data], headerType: UInt8,
                             granule: UInt64, serial: UInt32, seq: UInt32) -> Data {
        var segments: [UInt8] = []
        var payload = Data()
        for p in packets {
            var bytes = [UInt8](p)
            while bytes.count >= 255 {
                segments.append(255)
                payload.append(contentsOf: bytes.prefix(255))
                bytes.removeFirst(255)
            }
            segments.append(UInt8(bytes.count))
            payload.append(contentsOf: bytes)
        }
        guard segments.count <= 255 else { return Data() }   // 单页最大 255 段

        var d = Data([0x4F, 0x67, 0x67, 0x53])               // "OggS"
        d.append(0)                                          // version
        d.append(headerType)
        d.append(contentsOf: withUnsafeBytes(of: granule.littleEndian) { Array($0) })
        d.append(contentsOf: withUnsafeBytes(of: serial.littleEndian) { Array($0) })
        d.append(contentsOf: withUnsafeBytes(of: seq.littleEndian) { Array($0) })
        d.append(contentsOf: [0, 0, 0, 0])                   // CRC 占位
        d.append(UInt8(segments.count))
        d.append(contentsOf: segments)
        d.append(payload)

        // Ogg 专用 CRC32（多项式 0x04c11db7，覆盖整页、CRC 字段先置 0）
        let crc = oggCRC(d)
        d.replaceSubrange(22..<26, with: withUnsafeBytes(of: crc.littleEndian) { Data($0) })
        return d
    }

    private static let crcTable: [UInt32] = {
        (0..<256).map { i -> UInt32 in
            var r = UInt32(i) << 24
            for _ in 0..<8 {
                r = (r << 1) ^ ((r & 0x8000_0000) != 0 ? 0x04c1_1db7 : 0)
            }
            return r
        }
    }()

    private static func oggCRC(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0
        for b in data {
            crc = (crc << 8) ^ crcTable[Int((crc >> 24) & 0xFF) ^ Int(b)]
        }
        return crc
    }
}
