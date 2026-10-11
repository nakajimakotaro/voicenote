import AudioIO
import Domain
import Foundation
import SwiftData

/// 文字起こしの実行。ブロックどうしは並列、ブロックの中は順番に送る
/// （直前のセグメントのテキストを `prompt` に入れるため）。
/// 状態はSwiftDataからしか読まないので、どこで止まっても続きから動く。
/// メインスレッドで作ると処理もメインスレッドで動くので、必ずメインスレッドの外で作る
@ModelActor
actor TranscriptionQueue {
    struct Config: Sendable {
        var recordingId: UUID
        var sourceURL: URL
        var model: String
        var language: String
        var client: OpenAIClient
        var workers = 3
    }

    enum Event: Sendable {
        /// 429で全体を止めている。再開する時刻
        case rateLimited(until: Date)
        case resumed
    }

    static let maxAttempts = 3
    /// 429で `Retry-After` がないときに待つ時間
    static let defaultRateLimitWait: Duration = .seconds(20)
    /// API送信用のmp3（16kHzモノラル。48kbpsならLAMEタグが入る）
    static let sendSampleRate = 16_000.0
    static let sendKbps = 48
    /// `prompt` に入れる直前のテキストの長さ
    static let promptChars = 200

    private var remainingBlocks: [UUID] = []
    private var pausedUntil: ContinuousClock.Instant?

    /// 前回 `sending` のまま終わったセグメントを `pending` に戻す。戻したものがあった録音のidを返す
    func resetInterrupted() -> Set<UUID> {
        let sending = SegmentState.sending.rawValue
        let segments = (try? modelContext.fetch(FetchDescriptor<Segment>(predicate: #Predicate { $0.stateRaw == sending }))) ?? []
        var recordings = Set<UUID>()
        for segment in segments {
            segment.state = .pending
            if let id = segment.block?.recording?.id { recordings.insert(id) }
        }
        try? modelContext.save()
        return recordings
    }

    /// 採用したブロックの未完了のセグメントをすべて送る。401なら `OpenAIClient.Failure.unauthorized` を投げて全体を止める
    func run(_ config: Config, events: @escaping @Sendable (Event) -> Void) async throws {
        remainingBlocks = pendingBlocks(config.recordingId)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0 ..< min(config.workers, remainingBlocks.count) {
                group.addTask {
                    while let blockId = await self.nextBlock() {
                        try await self.transcribeBlock(blockId, config: config, events: events)
                    }
                }
            }
            // 1本が失敗したら残りもキャンセルする
            try await group.waitForAll()
        }
    }

    private func nextBlock() -> UUID? {
        remainingBlocks.isEmpty ? nil : remainingBlocks.removeFirst()
    }

    private func pendingBlocks(_ recordingId: UUID) -> [UUID] {
        let selected = BlockStatus.selected.rawValue
        let descriptor = FetchDescriptor<Block>(
            predicate: #Predicate { $0.recording?.id == recordingId && $0.statusRaw == selected },
            sortBy: [SortDescriptor(\.startMs)]
        )
        let blocks = (try? modelContext.fetch(descriptor)) ?? []
        return blocks.filter { $0.segments.contains { $0.state == .pending } }.map(\.id)
    }

    private func transcribeBlock(_ blockId: UUID, config: Config, events: @escaping @Sendable (Event) -> Void) async throws {
        guard let block = fetchBlock(blockId) else { return }
        let segments = block.segments.sorted { $0.startMs < $1.startMs }
        var previousText: String?
        for segment in segments {
            switch segment.state {
            case .done:
                previousText = segment.displayText
            case .failed:
                continue
            case .pending, .sending:
                if try await transcribe(segment, prompt: previousText, config: config, events: events) {
                    previousText = segment.text
                }
            }
        }
    }

    /// 1セグメントを送る。成功したらtrue。再試行しきれなければ `failed` にしてfalse
    private func transcribe(_ segment: Segment, prompt: String?, config: Config,
                            events: @escaping @Sendable (Event) -> Void) async throws -> Bool {
        let audio = FileLayout.tmpDir.appendingPathComponent("send-\(segment.id.uuidString).mp3")
        defer { try? FileManager.default.removeItem(at: audio) }
        while true {
            try await waitWhilePaused(events: events)
            segment.state = .sending
            save()
            do {
                try FileLayout.ensureDirectory(FileLayout.tmpDir)
                _ = try await renderMp3(input: config.sourceURL, ranges: [segment.range], output: audio,
                                        sampleRate: Self.sendSampleRate, kbps: Self.sendKbps, fadeMs: 10)
                let text = try await config.client.transcribe(.init(
                    audio: audio, model: config.model, language: config.language,
                    prompt: prompt.map { String($0.suffix(Self.promptChars)) }
                ))
                segment.text = text
                segment.editedText = nil
                segment.model = config.model
                segment.state = .done
                save()
                return true
            } catch is CancellationError {
                segment.state = .pending
                save()
                throw CancellationError()
            } catch OpenAIClient.Failure.unauthorized {
                segment.state = .pending
                save()
                throw OpenAIClient.Failure.unauthorized
            } catch OpenAIClient.Failure.rateLimited(let retryAfter) {
                // 回数には数えず、全体を止めてから同じセグメントを送り直す
                segment.state = .pending
                save()
                pause(for: retryAfter ?? Self.defaultRateLimitWait, events: events)
            } catch {
                segment.attempts += 1
                let retryable: Bool
                if case OpenAIClient.Failure.rejected = error { retryable = false } else { retryable = true }
                guard retryable, segment.attempts < Self.maxAttempts else {
                    segment.state = .failed
                    save()
                    return false
                }
                segment.state = .pending
                save()
                // 2秒、4秒、8秒…と間隔を空ける
                try await Task.sleep(for: .seconds(1 << segment.attempts))
            }
        }
    }

    private func pause(for duration: Duration, events: @escaping @Sendable (Event) -> Void) {
        let until = ContinuousClock.now + duration
        if let pausedUntil, pausedUntil >= until { return }
        pausedUntil = until
        let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        events(.rateLimited(until: Date().addingTimeInterval(seconds)))
    }

    private func waitWhilePaused(events: @escaping @Sendable (Event) -> Void) async throws {
        while let until = pausedUntil {
            if ContinuousClock.now >= until {
                pausedUntil = nil
                events(.resumed)
                return
            }
            try await Task.sleep(until: until, clock: .continuous)
        }
    }

    private func fetchBlock(_ id: UUID) -> Block? {
        try? modelContext.fetch(FetchDescriptor<Block>(predicate: #Predicate { $0.id == id })).first
    }

    private func save() {
        try? modelContext.save()
    }
}
