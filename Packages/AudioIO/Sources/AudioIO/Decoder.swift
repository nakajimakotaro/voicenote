import AVFoundation

/// 音声ファイルを指定のサンプルレートのモノラルFloat32に変換しながら少しずつ読む。
/// 全体をメモリに展開しない。1つのTaskの中だけで使う
final class PCMReader: @unchecked Sendable {
    let sampleRate: Double
    private let reader: AVAssetReader
    private let output: AVAssetReaderTrackOutput
    /// AVAssetReaderに触るのはこのキューの上だけ
    private let queue = DispatchQueue(label: "AudioIO.PCMReader")

    /// - Parameters:
    ///   - startMs: 読み始める位置。解析の再開やカット後の区間の切り出しに使う
    ///   - endMs: 読み終える位置。nilなら末尾まで
    init(url: URL, sampleRate: Double, startMs: Int = 0, endMs: Int? = nil) async throws {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw AudioIOError.noAudioTrack
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false

        let reader = try AVAssetReader(asset: asset)
        let start = CMTime(value: CMTimeValue(startMs), timescale: 1000)
        let duration = endMs.map { CMTime(value: CMTimeValue($0 - startMs), timescale: 1000) } ?? .positiveInfinity
        reader.timeRange = CMTimeRange(start: start, duration: duration)
        reader.add(output)
        guard reader.startReading() else {
            throw AudioIOError.unreadable(reader.error?.localizedDescription ?? "startReading")
        }
        self.sampleRate = sampleRate
        self.reader = reader
        self.output = output
    }

    deinit {
        if reader.status == .reading { reader.cancelReading() }
    }

    /// 次のまとまりのサンプルを `buffer` の末尾に足す。終端ならfalse
    func read(appendingTo buffer: inout [Float]) async throws -> Bool {
        guard let samples = try await next() else { return false }
        buffer.append(contentsOf: samples)
        return true
    }

    /// `copyNextSampleBuffer` はデコードが終わるまでスレッドを止める。Swift Concurrencyのスレッドで待つと、
    /// 同時に読む数がスレッドプールの幅（CPUコア数）に達したとき、AVFoundationの内部処理に回るスレッドが
    /// なくなってすべて止まる。そのため専用のキューで待ち、呼び出し側のスレッドは手放す
    private func next() async throws -> [Float]? {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result { try self.copyNext() })
            }
        }
    }

    /// 終端ならnil。データのないバッファなら空の配列
    private func copyNext() throws -> [Float]? {
        guard let sample = output.copyNextSampleBuffer() else {
            if reader.status == .failed {
                throw AudioIOError.unreadable(reader.error?.localizedDescription ?? "decode")
            }
            return nil
        }
        guard let block = CMSampleBufferGetDataBuffer(sample) else { return [] }
        let count = CMBlockBufferGetDataLength(block) / MemoryLayout<Float>.size
        guard count > 0 else { return [] }
        var samples = [Float](repeating: 0, count: count)
        let status = samples.withUnsafeMutableBytes { raw in
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count * MemoryLayout<Float>.size,
                                       destination: raw.baseAddress!)
        }
        guard status == kCMBlockBufferNoErr else { throw AudioIOError.unreadable("CMBlockBuffer \(status)") }
        return samples
    }
}
