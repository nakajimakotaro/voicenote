import AudioIO
import Domain
import Foundation
import Observation
import SwiftData

/// 文字起こしの開始・停止と、画面向けの状態。送信と保存は `TranscriptionQueue` が別のコンテキストで行い、
/// 画面はSwiftDataの変更を購読して進捗を描く。同時に実行するのは1つの録音だけ
@MainActor
@Observable
final class TranscriptionService {
    enum Stop: Equatable {
        /// APIキーが保存されていない
        case missingKey
        /// 401。設定画面でキーを入れ直してもらう
        case unauthorized
        case error(String)
    }

    /// 実行中の録音
    private(set) var runningId: UUID?
    /// 最後に止まった理由（録音ごと）。次に開始したら消える
    private(set) var stops: [UUID: Stop] = [:]
    /// 429で待っている間だけ、再開する時刻
    private(set) var rateLimitedUntil: Date?

    /// セグメントの最大の長さ
    nonisolated static let segmentMaxMs = 30_000

    private let container: ModelContainer
    private var context: ModelContext { container.mainContext }
    private var worker: Task<Stop?, Never>?
    /// 終わったあとの後始末まで含めたTask
    private var task: Task<Void, Never>?
    private let keychain = KeychainStore()

    init(container: ModelContainer) {
        self.container = container
    }

    /// 起動時に呼ぶ。送信中のまま終わったセグメントを戻し、その録音は続きから再開する。
    /// 自分で止めた録音（送信中のものがない）は再開しない
    func resumeInterrupted() async {
        let container = container
        let interrupted = await Task.detached {
            await TranscriptionQueue(modelContainer: container).resetInterrupted()
        }.value
        guard let id = interrupted.first, let recording = fetchRecording(id) else { return }
        await start(recording)
    }

    /// 採用したブロックのうち、セグメントで覆われていない部分を分ける。
    /// まだ分けていないブロックは全体、範囲を変えたブロックは空いた部分だけが対象になる
    func prepareSegments(_ recording: Recording) async throws {
        let targets = recording.blocks.compactMap { block -> (Block, [TimeRange])? in
            guard block.status == .selected else { return nil }
            let gaps = uncoveredRanges(block: block.range, covered: block.segments.map(\.range))
            return gaps.isEmpty ? nil : (block, gaps)
        }
        guard !targets.isEmpty else { return }
        let id = recording.id
        let gapLists = targets.map(\.1)
        let segmentRanges = try await Task.detached {
            let regions = try readRegions(from: FileLayout.regions(id))
            let peaks = try? PeakFile(url: FileLayout.peaks50(id))
            return gapLists.map { gaps in
                gaps.flatMap { gap in
                    buildSegments(block: gap, regions: regions, maxMs: Self.segmentMaxMs,
                                  quietestPoint: peaks.map { p in { window in Self.quietestMs(in: window, peaks: p) } })
                }
            }
        }.value
        for ((block, _), segments) in zip(targets, segmentRanges) {
            // 待っているあいだに覆われた部分には作らない
            let covered = block.segments.map(\.range)
            for range in segments where !covered.contains(where: { $0.overlaps(range) }) {
                let segment = Segment(startMs: range.startMs, endMs: range.endMs)
                context.insert(segment)
                segment.block = block
            }
        }
        try context.save()
    }

    /// 20msごとのピークで最も小さい位置（区間の中央）
    nonisolated static func quietestMs(in window: TimeRange, peaks: PeakFile) -> Int {
        let step = PeakFile.msPerPeak50
        let first = window.startMs / step
        let values = peaks.read(from: first, count: max(1, window.durationMs / step))
        guard let index = values.indices.min(by: { values[$0] < values[$1] }) else { return window.endMs }
        return (first + index) * step + step / 2
    }

    func start(_ recording: Recording) async {
        guard runningId == nil else { return }
        stops[recording.id] = nil
        let apiKey: String
        do {
            guard let key = try keychain.read(), !key.isEmpty else {
                stops[recording.id] = .missingKey
                return
            }
            apiKey = key
        } catch {
            stops[recording.id] = .error("APIキーを読み出せませんでした")
            return
        }
        do {
            try await prepareSegments(recording)
        } catch {
            stops[recording.id] = .error("解析結果を読み込めませんでした")
            return
        }

        let settings = AppSettings.current(in: context)
        let id = recording.id
        let config = TranscriptionQueue.Config(
            recordingId: id,
            sourceURL: FileLayout.source(id, fileName: recording.sourceFileName),
            model: AppSettings.transcriptionModel,
            language: settings.language,
            client: OpenAIClient(apiKey: apiKey, workDir: FileLayout.tmpDir)
        )
        runningId = id
        IdleTimer.set(.transcription, active: true)
        let container = container
        // キューはメインスレッドの外で作る。止めるときはこのTaskをキャンセルする
        let worker = Task.detached { () async -> Stop? in
            do {
                try await TranscriptionQueue(modelContainer: container).run(config) { event in
                    Task { @MainActor [weak self] in self?.handle(event) }
                }
                return nil
            } catch is CancellationError {
                return nil
            } catch OpenAIClient.Failure.unauthorized {
                return .unauthorized
            } catch {
                return .error("文字起こしを続けられませんでした")
            }
        }
        self.worker = worker
        task = Task {
            stops[id] = await worker.value
            runningId = nil
            rateLimitedUntil = nil
            self.worker = nil
            task = nil
            IdleTimer.set(.transcription, active: false)
        }
    }

    /// 設定画面から戻ったときに呼ぶ。キーが保存されていれば、キーが理由で止まった表示を消す
    func clearKeyStops() {
        guard let key = try? keychain.read(), !key.isEmpty else { return }
        stops = stops.filter { $0.value != .missingKey && $0.value != .unauthorized }
    }

    /// 止める。送信中のセグメントは未送信に戻る
    func stop() async {
        worker?.cancel()
        await task?.value
    }

    /// 失敗したセグメントを未送信に戻して、もう一度実行する
    func retryFailed(_ recording: Recording) async {
        for block in recording.blocks {
            for segment in block.segments where segment.state == .failed {
                segment.state = .pending
                segment.attempts = 0
            }
        }
        try? context.save()
        await start(recording)
    }

    private func handle(_ event: TranscriptionQueue.Event) {
        switch event {
        case .rateLimited(let until): rateLimitedUntil = until
        case .resumed: rateLimitedUntil = nil
        }
    }

    private func fetchRecording(_ id: UUID) -> Recording? {
        try? context.fetch(FetchDescriptor<Recording>(predicate: #Predicate { $0.id == id })).first
    }
}
