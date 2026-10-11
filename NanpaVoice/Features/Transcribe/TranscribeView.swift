import Domain
import SwiftData
import SwiftUI

/// 文字起こしの実行。対象と見積もりを出して実行し、ブロックごとの進捗と失敗したセグメントの再試行を出す
struct TranscribeView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(TranscriptionService.self) private var transcription
    let recording: Recording
    /// 送信は別のコンテキストで保存されるので、関連ではなく@Queryで購読して進捗を描く
    @Query private var segments: [Segment]
    @State private var showingSettings = false

    init(recording: Recording) {
        self.recording = recording
        let id = recording.id
        // `$0.block?.recording?.id` のように2段のオプショナルチェーンはSQLに変換できず落ちるので if let で辿る
        _segments = Query(filter: #Predicate<Segment> { segment in
            if let block = segment.block, let recording = block.recording {
                return recording.id == id
            } else {
                return false
            }
        }, sort: \.startMs)
    }

    private var isRunning: Bool { transcription.runningId == recording.id }

    var body: some View {
        let summary = TranscribeSummary(recording: recording, segments: segments,
                                        settings: AppSettings.current(in: modelContext))
        List {
            estimateSection(summary)
            controlSection(summary)
            Section("ブロック") {
                if summary.blocks.isEmpty {
                    Text("ブロック一覧で文字起こしするブロックにチェックを付けてください")
                        .foregroundStyle(.secondary)
                }
                ForEach(summary.blocks) { row in
                    BlockProgressRow(row: row)
                }
            }
        }
        .navigationTitle("文字起こし")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingSettings, onDismiss: { transcription.clearKeyStops() }) {
            SettingsView()
        }
        // ホームの設定でキーを入れてから戻ってきた場合も、古い表示を残さない
        .onAppear { transcription.clearKeyStops() }
    }

    private func estimateSection(_ summary: TranscribeSummary) -> some View {
        Section {
            LabeledContent("対象ブロック", value: "\(summary.blocks.count)件")
            LabeledContent("送信する長さ", value: Format.duration(ms: summary.pendingMs))
            LabeledContent("見積もり") {
                Text("\(Format.usd(summary.usd))（約\(Format.yen(summary.usd * AppSettings.yenPerUsd))）")
                    .monospacedDigit()
            }
        } footer: {
            Text("1分あたり\(Format.usd(summary.pricePerMinUsd))、1ドル\(Int(AppSettings.yenPerUsd))円で計算した目安です")
        }
    }

    @ViewBuilder
    private func controlSection(_ summary: TranscribeSummary) -> some View {
        Section {
            if isRunning {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: Double(summary.doneCount), total: Double(max(1, summary.totalCount)))
                    Text("\(summary.doneCount) / \(summary.totalCount) セグメント")
                        .font(.subheadline)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    if let until = transcription.rateLimitedUntil {
                        Text("混み合っているため待機中（\(until, style: .relative)後に再開）")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                }
                Button("停止", systemImage: "stop.fill", role: .destructive) {
                    Task { await transcription.stop() }
                }
            } else {
                Button(summary.doneCount > 0 ? "続きを文字起こし" : "文字起こしを開始", systemImage: "waveform.badge.mic") {
                    Task { await transcription.start(recording) }
                }
                .disabled(summary.pendingMs == 0 || transcription.runningId != nil)
                if transcription.runningId != nil {
                    Text("別の録音を文字起こし中です")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if summary.failedCount > 0 {
                    Button("失敗した\(summary.failedCount)件を再試行", systemImage: "arrow.clockwise") {
                        Task { await transcription.retryFailed(recording) }
                    }
                    .disabled(transcription.runningId != nil)
                }
            }
            if let stop = transcription.stops[recording.id] {
                stopMessage(stop)
            }
        } footer: {
            if isRunning {
                Text("実行中は画面をつけたままにしてください。途中で止まっても、続きから再開できます")
            }
        }
    }

    @ViewBuilder
    private func stopMessage(_ stop: TranscriptionService.Stop) -> some View {
        switch stop {
        case .missingKey, .unauthorized:
            VStack(alignment: .leading, spacing: 8) {
                Text(stop == .missingKey ? "APIキーが設定されていません" : "APIキーが正しくありません")
                    .foregroundStyle(.red)
                Button("設定を開く") { showingSettings = true }
                    .buttonStyle(.bordered)
            }
        case .error(let message):
            Text(message).foregroundStyle(.red)
        }
    }
}

/// 画面に出す集計。採用したブロックと、すでにセグメントに分けたブロックを対象にする
@MainActor
struct TranscribeSummary {
    struct BlockRow: Identifiable {
        let block: Block
        let number: Int
        let segments: [Segment]
        /// セグメントで覆われていない長さ。範囲を変えたブロックは、空いた部分を次の実行で送る
        let uncoveredMs: Int

        var id: UUID { block.id }
        var range: TimeRange { block.range }

        var displayTitle: String { block.title.isEmpty ? "ブロック \(number)" : block.title }
        var doneCount: Int { segments.filter { $0.state == .done }.count }
        var failedCount: Int { segments.filter { $0.state == .failed }.count }
        var isSending: Bool { segments.contains { $0.state == .sending } }
    }

    let blocks: [BlockRow]
    /// これから送る長さ。未送信のセグメントと、セグメントで覆われていない部分（まだ分けていないブロックは全体）
    let pendingMs: Int
    let pricePerMinUsd: Double

    init(recording: Recording, segments: [Segment], settings: AppSettings) {
        let byBlock = Dictionary(grouping: segments) { $0.block?.id }
        var rows: [BlockRow] = []
        var pendingMs = 0
        for (i, block) in BlockService.sorted(recording).enumerated() {
            let segs = byBlock[block.id] ?? []
            guard block.status == .selected || !segs.isEmpty else { continue }
            let uncoveredMs = block.status == .selected
                ? uncoveredRanges(block: block.range, covered: segs.map(\.range)).map(\.durationMs).reduce(0, +)
                : 0
            if block.status == .selected {
                pendingMs += uncoveredMs
                    + segs.filter { $0.state == .pending || $0.state == .sending }.map(\.range.durationMs).reduce(0, +)
            }
            rows.append(BlockRow(block: block, number: i + 1, segments: segs, uncoveredMs: uncoveredMs))
        }
        blocks = rows
        self.pendingMs = pendingMs
        pricePerMinUsd = settings.pricePerMinUsd
    }

    var usd: Double { estimateUsd(totalMs: pendingMs, pricePerMinUsd: pricePerMinUsd) }
    var totalCount: Int { blocks.map(\.segments.count).reduce(0, +) }
    var doneCount: Int { blocks.map(\.doneCount).reduce(0, +) }
    var failedCount: Int { blocks.map(\.failedCount).reduce(0, +) }
}

private struct BlockProgressRow: View {
    let row: TranscribeSummary.BlockRow

    var body: some View {
        DisclosureGroup {
            NavigationLink {
                EditorView(block: row.block)
            } label: {
                Label("エディタで開く", systemImage: "waveform")
            }
            ForEach(row.segments) { segment in
                SegmentTextRow(segment: segment)
            }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(row.displayTitle).font(.headline)
                    if row.isSending {
                        ProgressView().controlSize(.small)
                    }
                    Spacer()
                    Text(progressLabel)
                        .font(.subheadline)
                        .monospacedDigit()
                        .foregroundStyle(row.failedCount > 0 ? .red : .secondary)
                }
                Text("\(Format.duration(ms: row.range.startMs))〜 長さ \(Format.duration(ms: row.range.durationMs))")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                if !row.segments.isEmpty {
                    ProgressView(value: Double(row.doneCount), total: Double(row.segments.count))
                        .tint(row.failedCount > 0 ? .red : nil)
                }
            }
        }
        .disabled(row.segments.isEmpty)
    }

    private var progressLabel: String {
        guard !row.segments.isEmpty else { return "未実行" }
        var label = "\(row.doneCount)/\(row.segments.count)"
        if row.failedCount > 0 { label += "（失敗 \(row.failedCount)）" }
        if row.uncoveredMs > 0 { label += "・未実行 \(Format.duration(ms: row.uncoveredMs))" }
        return label
    }
}

private struct SegmentTextRow: View {
    let segment: Segment

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(Format.duration(ms: segment.startMs))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            switch segment.state {
            case .done:
                Text(segment.displayText.isEmpty ? "（発話なし）" : segment.displayText)
                    .font(.subheadline)
                    .foregroundStyle(segment.displayText.isEmpty ? .secondary : .primary)
            case .failed:
                Text("失敗しました").font(.subheadline).foregroundStyle(.red)
            case .sending:
                Text("送信中…").font(.subheadline).foregroundStyle(.secondary)
            case .pending:
                Text("未送信").font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }
}
