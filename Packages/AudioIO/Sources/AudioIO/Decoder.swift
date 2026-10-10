import AVFoundation

/// 音声ファイルを指定のサンプルレートのモノラルFloat32に変換しながら少しずつ読む。
/// 全体をメモリに展開しない。1つのTaskの中だけで使う
final class PCMReader {
    let sampleRate: Double
    private let reader: AVAssetReader
    private let output: AVAssetReaderTrackOutput

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
    func read(appendingTo buffer: inout [Float]) throws -> Bool {
        guard let sample = output.copyNextSampleBuffer() else {
            if reader.status == .failed {
                throw AudioIOError.unreadable(reader.error?.localizedDescription ?? "decode")
            }
            return false
        }
        guard let block = CMSampleBufferGetDataBuffer(sample) else { return true }
        let count = CMBlockBufferGetDataLength(block) / MemoryLayout<Float>.size
        guard count > 0 else { return true }
        let oldCount = buffer.count
        buffer.append(contentsOf: repeatElement(0, count: count))
        let status = buffer.withUnsafeMutableBytes { raw in
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count * MemoryLayout<Float>.size,
                                       destination: raw.baseAddress! + oldCount * MemoryLayout<Float>.size)
        }
        guard status == kCMBlockBufferNoErr else { throw AudioIOError.unreadable("CMBlockBuffer \(status)") }
        return true
    }
}
