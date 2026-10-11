import CLame
import Domain
import Foundation

public struct Mp3Result: Sendable, Hashable {
    public let durationMs: Int
    public let bytes: Int
}

/// `ranges` の区間を順につないでモノラルのmp3にする。API送信用（16kHz）と書き出し（44.1kHz）で共用する。
/// 区間ごとにデコードしてLAMEへ流すので、全体をメモリに持たない。
/// 区間の両端に `fadeMs` のフェードをかけて、つなぎ目のプツッという音を防ぐ。
/// 途中で失敗したりキャンセルされたりしたら `output` を消す
public func renderMp3(input: URL, ranges: [TimeRange], output: URL, sampleRate: Double,
                      kbps: Int, fadeMs: Int) async throws -> Mp3Result {
    do {
        return try await Mp3Renderer(input: input, sampleRate: sampleRate, kbps: kbps, fadeMs: fadeMs)
            .render(ranges: ranges, to: output)
    } catch {
        try? FileManager.default.removeItem(at: output)
        throw error
    }
}

struct Mp3Renderer {
    let input: URL
    let sampleRate: Double
    let kbps: Int
    let fadeMs: Int

    func render(ranges: [TimeRange], to output: URL) async throws -> Mp3Result {
        let encoder = try Mp3Encoder(sampleRate: sampleRate, kbps: kbps)
        FileManager.default.createFile(atPath: output.path, contents: nil)
        let file = try FileHandle(forWritingTo: output)
        defer { try? file.close() }

        let fadeSamples = fadeMs * Int(sampleRate) / 1000
        var totalSamples = 0
        for range in ranges where !range.isEmpty {
            try Task.checkCancellation()
            let reader = try await PCMReader(url: input, sampleRate: sampleRate, startMs: range.startMs, endMs: range.endMs)
            // 区間の外のサンプルが混ざっても、区間の長さを超えた分は捨てる
            let limit = range.durationMs * Int(sampleRate) / 1000
            var fade = Fade(samples: fadeSamples)
            var pending: [Float] = []
            var more = true
            while more {
                try Task.checkCancellation()
                more = try await reader.read(appendingTo: &pending)
                if fade.position + pending.count > limit {
                    pending.removeLast(fade.position + pending.count - limit)
                    more = false
                }
                // 末尾のフェードのために最後の `fadeSamples` 個は次の読み込みまで残す
                let ready = more ? max(0, pending.count - fadeSamples) : pending.count
                guard ready > 0 else { continue }
                var chunk = Array(pending[..<ready])
                pending.removeFirst(ready)
                fade.applyIn(&chunk)
                if !more { fade.applyOut(&chunk) }
                try file.write(contentsOf: encoder.encode(chunk))
                totalSamples += chunk.count
            }
        }
        try file.write(contentsOf: encoder.flush())
        // 先頭に置いた仮のフレームを、長さとエンコーダーの遅延を書いたLAMEタグで上書きする
        if let tag = encoder.lameTag() {
            try file.seek(toOffset: 0)
            try file.write(contentsOf: tag)
        }
        let bytes = try file.seekToEnd()
        return Mp3Result(durationMs: Int((Double(totalSamples) / sampleRate * 1000).rounded()), bytes: Int(bytes))
    }
}

/// 区間の始まりと終わりに直線のフェードをかける
struct Fade {
    let samples: Int
    /// 区間の先頭から数えた、次に来るサンプルの位置
    private(set) var position = 0

    init(samples: Int) {
        self.samples = samples
    }

    mutating func applyIn(_ chunk: inout [Float]) {
        if samples > 0 {
            for i in 0 ..< min(chunk.count, max(0, samples - position)) {
                chunk[i] *= Float(position + i) / Float(samples)
            }
        }
        position += chunk.count
    }

    /// `chunk` が区間の最後のまとまりのときに呼ぶ
    func applyOut(_ chunk: inout [Float]) {
        guard samples > 0 else { return }
        let n = min(chunk.count, samples)
        for i in 0 ..< n {
            chunk[chunk.count - 1 - i] *= Float(i) / Float(samples)
        }
    }
}

/// LAMEのラッパー。モノラルCBR。1つのTaskの中だけで使う
final class Mp3Encoder {
    private let lame: lame_t

    init(sampleRate: Double, kbps: Int) throws {
        guard let lame = lame_init() else { throw AudioIOError.encoder("lame_init") }
        self.lame = lame
        lame_set_in_samplerate(lame, Int32(sampleRate))
        lame_set_out_samplerate(lame, Int32(sampleRate))
        lame_set_num_channels(lame, 1)
        lame_set_mode(lame, MONO)
        lame_set_VBR(lame, vbr_off)
        lame_set_brate(lame, Int32(kbps))
        lame_set_quality(lame, 5)
        // ID3タグは書かない。先頭のフレームを最後にLAMEタグで上書きする。
        // フレームがタグより小さい設定（16kHz・32kbpsなど）では、LAMEがタグを書かずに進める
        lame_set_write_id3tag_automatic(lame, 0)
        lame_set_bWriteVbrTag(lame, 1)
        // 標準エラーへのメッセージを出さない
        lame_set_errorf(lame, nil)
        lame_set_debugf(lame, nil)
        lame_set_msgf(lame, nil)
        guard lame_init_params(lame) >= 0 else {
            lame_close(lame)
            throw AudioIOError.encoder("lame_init_params")
        }
    }

    deinit {
        lame_close(lame)
    }

    /// -1〜1のサンプルをエンコードし、できたmp3のバイト列を返す
    func encode(_ samples: [Float]) throws -> Data {
        guard !samples.isEmpty else { return Data() }
        // LAMEの説明にある最悪の場合の大きさ（1.25倍 + 7200）
        var out = [UInt8](repeating: 0, count: samples.count * 5 / 4 + 7_200)
        let n = samples.withUnsafeBufferPointer { pcm in
            out.withUnsafeMutableBufferPointer { buf in
                lame_encode_buffer_ieee_float(lame, pcm.baseAddress, pcm.baseAddress, Int32(samples.count),
                                              buf.baseAddress, Int32(buf.count))
            }
        }
        guard n >= 0 else { throw AudioIOError.encoder("lame_encode_buffer \(n)") }
        return Data(out[..<Int(n)])
    }

    /// 残りをすべて書き出す
    func flush() throws -> Data {
        var out = [UInt8](repeating: 0, count: 7_200)
        let n = out.withUnsafeMutableBufferPointer { lame_encode_flush(lame, $0.baseAddress, Int32($0.count)) }
        guard n >= 0 else { throw AudioIOError.encoder("lame_encode_flush \(n)") }
        return Data(out[..<Int(n)])
    }

    /// `flush` のあとに呼ぶ。ファイルの先頭のフレームと置き換えるLAMEタグ。書かない設定ならnil
    func lameTag() -> Data? {
        var out = [UInt8](repeating: 0, count: 2_880)
        let n = out.withUnsafeMutableBufferPointer { lame_get_lametag_frame(lame, $0.baseAddress, $0.count) }
        guard n > 0, n <= out.count else { return nil }
        return Data(out[..<n])
    }
}
