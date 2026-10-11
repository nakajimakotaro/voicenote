import Domain
import Foundation
import Testing
@testable import AudioIO

/// 日本語の読み上げ2文を無音でつないだ17.8秒の音声。発話は 2.0〜7.4秒 と 11.4〜15.8秒
let speechURL = Bundle.module.url(forResource: "speech", withExtension: "m4a")!
let speechA = TimeRange(startMs: 2_022, endMs: 7_390)
let speechB = TimeRange(startMs: 11_430, endMs: 15_790)

/// テストごとの一時フォルダに解析ファイルを置く
func makeFiles() throws -> (AnalysisFiles, URL) {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("analysis-\(UUID())", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let files = AnalysisFiles(regions: dir.appendingPathComponent("regions.jsonl"),
                              checkpoint: dir.appendingPathComponent("checkpoint.json"),
                              peaks50: dir.appendingPathComponent("peaks_50.bin"),
                              peaks1: dir.appendingPathComponent("peaks_1.bin"))
    return (files, dir)
}

/// 進捗を集める
final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [AnalysisProgress] = []
    func append(_ p: AnalysisProgress) { lock.withLock { items.append(p) } }
    var all: [AnalysisProgress] { lock.withLock { items } }
}

struct DecoderTests {
    @Test func convertsToMono16k() async throws {
        let url = try makeSineWav(seconds: 2.5, sampleRate: 44_100, channels: 2)
        defer { try? FileManager.default.removeItem(at: url) }

        let reader = try await PCMReader(url: url, sampleRate: 16_000)
        var samples: [Float] = []
        while try await reader.read(appendingTo: &samples) {}
        #expect(abs(samples.count - 40_000) <= 16)
        // AVAssetReaderは等パワーで混ぜる（各チャンネル×1/√2の和）。両チャンネルが同じ0.3のサイン波なら約0.42
        let peak = samples.map(abs).max() ?? 0
        #expect(abs(peak - 0.3 * Float(2).squareRoot()) < 0.02)
    }

    @Test func startsFromOffset() async throws {
        let reader = try await PCMReader(url: speechURL, sampleRate: 16_000, startMs: 12_000)
        var samples: [Float] = []
        while try await reader.read(appendingTo: &samples) {}
        #expect(abs(samples.count - (17_820 - 12_000) * 16) <= 16 * 30)
    }
}

struct SileroVADTests {
    @Test func detectsSpeechInFixture() async throws {
        let vad = try SileroVAD()
        let reader = try await PCMReader(url: speechURL, sampleRate: 16_000)
        var samples: [Float] = []
        while try await reader.read(appendingTo: &samples) {}

        var probs: [(ms: Int, p: Float)] = []
        for start in stride(from: 0, to: samples.count, by: 512) {
            let frame = samples[start ..< min(start + 512, samples.count)]
            probs.append((start / 16, try vad.probability(frame)))
        }
        let silence = probs.filter { $0.ms < 1_500 || (8_500 ..< 10_500).contains($0.ms) || $0.ms > 16_500 }
        let speech = probs.filter { (3_000 ..< 6_500).contains($0.ms) || (12_000 ..< 15_000).contains($0.ms) }
        #expect(silence.allSatisfy { $0.p < 0.2 })
        let speechRatio = Double(speech.filter { $0.p > 0.5 }.count) / Double(speech.count)
        #expect(speechRatio > 0.8)
    }

    @Test func stateRoundTrip() throws {
        let vad = try SileroVAD()
        let frame = ArraySlice((0 ..< 512).map { Float(sin(Double($0) * 0.1)) * 0.3 })
        _ = try vad.probability(frame)
        let saved = vad.state
        let expected = try vad.probability(frame)

        let restored = try SileroVAD()
        restored.state = saved
        #expect(try restored.probability(frame) == expected)
    }
}

struct AnalyzerTests {
    @Test func writesRegionsAndPeaks() async throws {
        let (files, dir) = try makeFiles()
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = ProgressLog()

        try await analyze(input: speechURL, files: files, vad: VADParams(), progress: log.append)

        let regions = try readRegions(from: files.regions)
        #expect(!regions.isEmpty)
        // すべての区間が2つの発話のどちらかの近くにあり、それぞれの発話をほぼ覆う
        let slack = 300
        for r in regions {
            let nearA = r.startMs >= speechA.startMs - slack && r.endMs <= speechA.endMs + slack
            let nearB = r.startMs >= speechB.startMs - slack && r.endMs <= speechB.endMs + slack
            #expect(nearA || nearB, "想定外の区間 \(r)")
        }
        for speech in [speechA, speechB] {
            let covered = regions.compactMap { $0.intersection(speech)?.durationMs }.reduce(0, +)
            #expect(Double(covered) / Double(speech.durationMs) > 0.85)
        }

        let peaks50 = try PeakFile(url: files.peaks50)
        let peaks1 = try PeakFile(url: files.peaks1)
        let totalMs = log.all.last!.processedMs
        #expect(abs(totalMs - 17_820) <= 30)
        #expect(abs(peaks50.count - totalMs / 20) <= 1)
        #expect(peaks1.count == (peaks50.count + 49) / 50)
        // 無音の部分は小さく、発話の部分は大きい
        #expect(peaks50.read(from: 0, count: 50).max()! < 40)
        #expect(peaks50.read(from: 150, count: 50).max()! > 100)
        #expect(log.all.last!.durationMs == totalMs)
    }

    @Test func secondRunAfterFinishDoesNothing() async throws {
        let (files, dir) = try makeFiles()
        defer { try? FileManager.default.removeItem(at: dir) }
        try await analyze(input: speechURL, files: files, vad: VADParams()) { _ in }
        let before = try Data(contentsOf: files.regions)

        let log = ProgressLog()
        try await analyze(input: speechURL, files: files, vad: VADParams(), progress: log.append)
        #expect(log.all.count == 1)
        #expect(try Data(contentsOf: files.regions) == before)
    }

    /// 途中で止めてから再開しても、通しで処理したときと同じファイルになる
    @Test func resumeProducesIdenticalOutput() async throws {
        let (reference, refDir) = try makeFiles()
        defer { try? FileManager.default.removeItem(at: refDir) }
        try await Analyzer(input: speechURL, files: reference, params: VADParams(), checkpointIntervalMs: 4_000)
            .run { _ in }

        let (files, dir) = try makeFiles()
        defer { try? FileManager.default.removeItem(at: dir) }
        // 9秒を過ぎたところで止める（4秒と8秒のチェックポイントが書かれている）
        let task = Task {
            try await Analyzer(input: speechURL, files: files, params: VADParams(),
                               checkpointIntervalMs: 4_000, progressInterval: .zero)
                .run { p in if p.processedMs >= 9_000 { withUnsafeCurrentTask { $0?.cancel() } } }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        let checkpoint = try JSONDecoder().decode(Checkpoint.self, from: Data(contentsOf: files.checkpoint))
        #expect(checkpoint.processedMs >= 8_000 && !checkpoint.finished)

        try await Analyzer(input: speechURL, files: files, params: VADParams(), checkpointIntervalMs: 4_000)
            .run { _ in }
        #expect(try Data(contentsOf: files.regions) == Data(contentsOf: reference.regions))
        #expect(try Data(contentsOf: files.peaks50) == Data(contentsOf: reference.peaks50))
        #expect(try Data(contentsOf: files.peaks1) == Data(contentsOf: reference.peaks1))
    }

    @Test func changedParamsStartOver() async throws {
        let (files, dir) = try makeFiles()
        defer { try? FileManager.default.removeItem(at: dir) }
        try await analyze(input: speechURL, files: files, vad: VADParams()) { _ in }

        let log = ProgressLog()
        try await analyze(input: speechURL, files: files, vad: VADParams(threshold: 0.6), progress: log.append)
        #expect(log.all.first?.processedMs == 0)
        #expect(log.all.count > 1)
    }
}
