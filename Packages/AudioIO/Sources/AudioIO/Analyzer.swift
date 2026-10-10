import Accelerate
import Domain
import Foundation

/// 解析結果を書き込むファイル。パスはアプリ側（FileLayout）が決める
public struct AnalysisFiles: Sendable {
    /// 発話区間。1行に1つのJSON（`{"endMs":…,"startMs":…}`）
    public var regions: URL
    /// 再開位置と内部状態
    public var checkpoint: URL
    /// 20msごとのピーク
    public var peaks50: URL
    /// 1秒ごとのピーク
    public var peaks1: URL

    public init(regions: URL, checkpoint: URL, peaks50: URL, peaks1: URL) {
        self.regions = regions
        self.checkpoint = checkpoint
        self.peaks50 = peaks50
        self.peaks1 = peaks1
    }
}

/// 音声を16kHzモノラルで少しずつデコードし、発話区間とピークをファイルに書く。
/// `files.checkpoint` があればその続きから処理する。完了済みなら何もせず終わる。
/// 重い処理なのでメインスレッドの外で走る。止めるときは呼び出し側のTaskをキャンセルし、
/// この関数が戻るのを待ってから次の処理を始める（同じファイルを2つの処理が書かないように）
public func analyze(input: URL, files: AnalysisFiles, vad: VADParams,
                    progress: @Sendable (AnalysisProgress) -> Void) async throws {
    try await Analyzer(input: input, files: files, params: vad).run(progress: progress)
}

/// regions.jsonl を読む
public func readRegions(from url: URL) throws -> [TimeRange] {
    guard FileManager.default.fileExists(atPath: url.path) else { return [] }
    let decoder = JSONDecoder()
    return try Data(contentsOf: url)
        .split(separator: UInt8(ascii: "\n"))
        .map { try decoder.decode(TimeRange.self, from: Data($0)) }
}

struct Checkpoint: Codable {
    var processedMs: Int
    var finished: Bool
    var regionsBytes: UInt64
    var peaks50Count: UInt64
    var peaks1Count: UInt64
    var segmenter: VADSegmenter
    var vad: VADState
}

struct Analyzer {
    static let sampleRate = SileroVAD.sampleRate
    static let samplesPerMs = Int(sampleRate) / 1000
    static let peak50Samples = PeakFile.msPerPeak50 * samplesPerMs
    static let peaksPerPeak1 = PeakFile.msPerPeak1 / PeakFile.msPerPeak50
    /// VADの1フレーム（32ms）とピークの1区間（20ms）の両方で割り切れる単位（160ms）
    static let unitSamples = 2_560
    /// 進捗を知らせる音声上の間隔
    static let progressIntervalMs = 1_000

    let input: URL
    let files: AnalysisFiles
    let params: VADParams
    /// チェックポイントの間隔。4秒の倍数にすると、単位（160ms）と1秒の両方で割り切れて、
    /// 書いた時点で途中のピークが残らない
    let checkpointIntervalMs: Int
    /// 解析は実時間よりずっと速いので、進捗は実際の時間でも間引く
    let progressInterval: Duration

    init(input: URL, files: AnalysisFiles, params: VADParams,
         checkpointIntervalMs: Int = 20_000, progressInterval: Duration = .milliseconds(100)) {
        precondition(checkpointIntervalMs > 0 && checkpointIntervalMs % 4_000 == 0)
        self.input = input
        self.files = files
        self.params = params
        self.checkpointIntervalMs = checkpointIntervalMs
        self.progressInterval = progressInterval
    }

    func run(progress: (AnalysisProgress) -> Void) async throws {
        let info = try await audioInfo(of: input)
        let resumed = loadCheckpoint()
        if let resumed, resumed.finished {
            progress(AnalysisProgress(processedMs: resumed.processedMs, durationMs: resumed.processedMs))
            return
        }

        let vad = try SileroVAD()
        var segmenter = VADSegmenter(params: params)
        var processed = 0
        let out: Outputs
        if let resumed {
            vad.state = resumed.vad
            segmenter = resumed.segmenter
            processed = resumed.processedMs * Self.samplesPerMs
            out = try Outputs(files: files, truncatingTo: resumed)
        } else {
            out = try Outputs(files: files, truncatingTo: nil)
        }
        defer { out.close() }

        let reader = try await PCMReader(url: input, sampleRate: Self.sampleRate, startMs: processed / Self.samplesPerMs)
        var pending: [Float] = []
        var peak1Max: Float = 0
        var peak1Frames = 0
        var lastReportedMs = processed / Self.samplesPerMs
        var lastReportedAt = ContinuousClock.now
        progress(AnalysisProgress(processedMs: processed / Self.samplesPerMs, durationMs: info.durationMs))

        var more = true
        while more {
            try Task.checkCancellation()
            more = try reader.read(appendingTo: &pending)
            var offset = 0
            while pending.count - offset >= Self.unitSamples || (!more && offset < pending.count) {
                let n = min(Self.unitSamples, pending.count - offset)
                let unit = pending[offset ..< offset + n]

                for f in stride(from: 0, to: n, by: SileroVAD.frameSamples) {
                    let frame = unit.dropFirst(f).prefix(SileroVAD.frameSamples)
                    let prob = try vad.probability(frame)
                    let startMs = (processed + f) / Self.samplesPerMs
                    let endMs = (processed + f + frame.count) / Self.samplesPerMs
                    if let region = segmenter.push(prob: prob, startMs: startMs, endMs: endMs) {
                        try out.append(region: region)
                    }
                }
                for p in stride(from: 0, to: n, by: Self.peak50Samples) {
                    let slice = unit.dropFirst(p).prefix(Self.peak50Samples)
                    let peak = vDSP.maximumMagnitude(slice)
                    out.peaks50.append(PeakFile.quantize(peak))
                    peak1Max = max(peak1Max, peak)
                    peak1Frames += 1
                    if peak1Frames == Self.peaksPerPeak1 {
                        out.peaks1.append(PeakFile.quantize(peak1Max))
                        peak1Max = 0
                        peak1Frames = 0
                    }
                }

                offset += n
                processed += n
                if processed % (checkpointIntervalMs * Self.samplesPerMs) == 0 {
                    try out.flush()
                    try save(Checkpoint(processedMs: processed / Self.samplesPerMs, finished: false,
                                        regionsBytes: out.regionsBytes, peaks50Count: out.peaks50Count,
                                        peaks1Count: out.peaks1Count, segmenter: segmenter, vad: vad.state))
                }
            }
            pending.removeFirst(offset)

            let processedMs = processed / Self.samplesPerMs
            if processedMs - lastReportedMs >= Self.progressIntervalMs,
               ContinuousClock.now - lastReportedAt >= progressInterval {
                lastReportedMs = processedMs
                lastReportedAt = .now
                progress(AnalysisProgress(processedMs: min(processedMs, info.durationMs), durationMs: info.durationMs))
            }
        }

        let totalMs = processed / Self.samplesPerMs
        if let region = segmenter.finish(totalMs: totalMs) {
            try out.append(region: region)
        }
        if peak1Frames > 0 {
            out.peaks1.append(PeakFile.quantize(peak1Max))
        }
        try out.flush()
        try save(Checkpoint(processedMs: totalMs, finished: true,
                            regionsBytes: out.regionsBytes, peaks50Count: out.peaks50Count,
                            peaks1Count: out.peaks1Count, segmenter: segmenter, vad: vad.state))
        progress(AnalysisProgress(processedMs: totalMs, durationMs: totalMs))
    }

    /// 同じパラメータで途中まで進んだチェックポイント。
    /// パラメータが変わっていたり、ファイルが記録より短かったりしたら最初からやり直す
    private func loadCheckpoint() -> Checkpoint? {
        guard let data = try? Data(contentsOf: files.checkpoint),
              let checkpoint = try? JSONDecoder().decode(Checkpoint.self, from: data),
              checkpoint.segmenter.params == params else { return nil }
        func size(_ url: URL) -> UInt64 {
            ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.uint64Value ?? 0
        }
        guard size(files.regions) >= checkpoint.regionsBytes,
              size(files.peaks50) >= checkpoint.peaks50Count,
              size(files.peaks1) >= checkpoint.peaks1Count else { return nil }
        return checkpoint
    }

    private func save(_ checkpoint: Checkpoint) throws {
        try JSONEncoder().encode(checkpoint).write(to: files.checkpoint, options: .atomic)
    }
}

/// 解析結果のファイルへの書き込み。小さな書き込みはためておき、flushでまとめて書く
private final class Outputs {
    private let regionsHandle: FileHandle
    private let peaks50Handle: FileHandle
    private let peaks1Handle: FileHandle
    private var regionsBuffer = Data()
    var peaks50 = Data()
    var peaks1 = Data()
    private(set) var regionsBytes: UInt64
    private(set) var peaks50Count: UInt64
    private(set) var peaks1Count: UInt64
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = .sortedKeys
        return e
    }()

    /// checkpoint があれば各ファイルをその時点の長さに切り詰める。なければ空にする
    init(files: AnalysisFiles, truncatingTo checkpoint: Checkpoint?) throws {
        func open(_ url: URL, length: UInt64) throws -> FileHandle {
            let fm = FileManager.default
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !fm.fileExists(atPath: url.path) {
                guard length == 0 else { throw AudioIOError.unreadable("missing \(url.lastPathComponent)") }
                fm.createFile(atPath: url.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: length)
            try handle.seekToEnd()
            return handle
        }
        regionsBytes = checkpoint?.regionsBytes ?? 0
        peaks50Count = checkpoint?.peaks50Count ?? 0
        peaks1Count = checkpoint?.peaks1Count ?? 0
        regionsHandle = try open(files.regions, length: regionsBytes)
        peaks50Handle = try open(files.peaks50, length: peaks50Count)
        peaks1Handle = try open(files.peaks1, length: peaks1Count)
    }

    func append(region: TimeRange) throws {
        regionsBuffer.append(try encoder.encode(region))
        regionsBuffer.append(UInt8(ascii: "\n"))
    }

    func flush() throws {
        try regionsHandle.write(contentsOf: regionsBuffer)
        try peaks50Handle.write(contentsOf: peaks50)
        try peaks1Handle.write(contentsOf: peaks1)
        regionsBytes += UInt64(regionsBuffer.count)
        peaks50Count += UInt64(peaks50.count)
        peaks1Count += UInt64(peaks1.count)
        regionsBuffer.removeAll(keepingCapacity: true)
        peaks50.removeAll(keepingCapacity: true)
        peaks1.removeAll(keepingCapacity: true)
    }

    func close() {
        try? regionsHandle.close()
        try? peaks50Handle.close()
        try? peaks1Handle.close()
    }
}
