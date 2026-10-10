import AudioIO
import Foundation
import Observation
import SwiftData

/// 録音の解析を1本ずつ順に実行する。重い処理はAudioIOがメインスレッドの外で行い、
/// ここは順番待ち、SwiftDataへの状態の書き込み、画面向けの進捗だけを受け持つ
@MainActor
@Observable
final class AnalysisService {
    struct LiveProgress {
        var processedMs: Int
        var durationMs: Int
        /// 処理の速さから出した残り時間の目安
        var remaining: Duration?
    }

    /// 実行中の録音の進捗
    private(set) var live: [UUID: LiveProgress] = [:]
    private(set) var currentId: UUID?

    private var queue: [UUID] = []
    private var currentTask: Task<Void, Never>?
    /// 残り時間の目安を出すための、今回の実行の開始時刻と開始位置
    private var session: (startedAt: ContinuousClock.Instant, startMs: Int?)?
    private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    /// 解析が終わっていない録音をすべて順番待ちに入れる（起動時）。
    /// 前回途中で止まったものは checkpoint.json の続きから再開する
    func resumeUnfinished() {
        let descriptor = FetchDescriptor<Recording>(sortBy: [SortDescriptor(\.createdAt)])
        let recordings = (try? context.fetch(descriptor)) ?? []
        for recording in recordings where recording.analysisState == .pending || recording.analysisState == .running {
            if recording.analysisState == .running { recording.analysisState = .pending }
            enqueue(recording.id)
        }
        try? context.save()
    }

    func enqueue(_ id: UUID) {
        guard currentId != id, !queue.contains(id) else { return }
        queue.append(id)
        pump()
    }

    /// 失敗した解析をやり直す
    func retry(_ recording: Recording) {
        recording.analysisState = .pending
        recording.analysisErrorMessage = nil
        try? context.save()
        enqueue(recording.id)
    }

    /// 順番待ちから外し、実行中なら止まるまで待つ（録音を削除する前に呼ぶ）
    func cancel(_ id: UUID) async {
        queue.removeAll { $0 == id }
        if currentId == id, let task = currentTask {
            task.cancel()
            await task.value
        }
    }

    private func pump() {
        guard currentTask == nil, !queue.isEmpty else {
            updateIdleTimer()
            return
        }
        let id = queue.removeFirst()
        currentId = id
        currentTask = Task {
            await run(id)
            currentId = nil
            currentTask = nil
            pump()
        }
        updateIdleTimer()
    }

    private func run(_ id: UUID) async {
        guard let recording = fetch(id) else { return }
        recording.analysisState = .running
        recording.analysisErrorMessage = nil
        try? context.save()

        session = (ContinuousClock.now, nil)
        live[id] = LiveProgress(processedMs: recording.analysisProgressMs, durationMs: recording.durationMs)

        let input = FileLayout.source(id, fileName: recording.sourceFileName)
        do {
            try await analyze(input: input, files: FileLayout.analysisFiles(id), vad: VADParams()) { p in
                Task { @MainActor [weak self] in
                    guard let self, self.currentId == id else { return }
                    self.report(id, p)
                }
            }
            recording.analysisState = .done
            recording.analysisProgressMs = recording.durationMs
        } catch is CancellationError {
            recording.analysisState = .pending
        } catch {
            recording.analysisState = .error
            recording.analysisErrorMessage = "音声を解析できませんでした（\(error.localizedDescription)）"
        }
        live[id] = nil
        session = nil
        try? context.save()
    }

    private func report(_ id: UUID, _ p: AnalysisProgress) {
        guard let session else { return }
        // 最初の通知の位置（再開ならチェックポイントの位置）から測る
        let startMs = session.startMs ?? p.processedMs
        self.session?.startMs = startMs
        var remaining: Duration?
        let done = p.processedMs - startMs
        let elapsed = ContinuousClock.now - session.startedAt
        // 始めの数秒は速さが安定しないので出さない
        if done > 0, elapsed > .seconds(2) {
            remaining = elapsed * (Double(p.durationMs - p.processedMs) / Double(done))
        }
        live[id] = LiveProgress(processedMs: p.processedMs, durationMs: p.durationMs, remaining: remaining)
        // 表示用の進捗。SwiftDataへの保存は自動保存に任せる
        fetch(id)?.analysisProgressMs = p.processedMs
    }

    private func fetch(_ id: UUID) -> Recording? {
        try? context.fetch(FetchDescriptor<Recording>(predicate: #Predicate { $0.id == id })).first
    }

    /// 解析中は画面を消さない（裏に回ると処理が止まるため）
    private func updateIdleTimer() {
        IdleTimer.set(.analysis, active: currentTask != nil)
    }
}
