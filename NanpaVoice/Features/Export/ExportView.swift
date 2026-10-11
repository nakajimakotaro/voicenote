import Domain
import SwiftData
import SwiftUI
import UIKit

/// 書き出し。ブロックと形式（txt / mp3 / 両方）を選んでファイルを作り、共有シートで送る
struct ExportView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    let recording: Recording
    /// 文字起こしは別のコンテキストで保存されるので、関連ではなく@Queryで購読する
    @Query private var segments: [Segment]
    @State private var selectedIds: Set<UUID>
    @State private var kind: ExportService.Kind = .both
    @State private var combineTxt = true
    @State private var phase: Phase = .idle
    @State private var task: Task<Void, Never>?
    @State private var copied = false

    enum Phase {
        case idle
        case working(done: Int, total: Int)
        case finished(ExportService.Output)
        case failed(String)
    }

    /// - Parameter blockIds: 最初に選んでおくブロック。nilなら文字起こし済みのブロックすべて
    init(recording: Recording, blockIds: Set<UUID>? = nil) {
        self.recording = recording
        let id = recording.id
        _segments = Query(filter: #Predicate<Segment> { segment in
            if let block = segment.block, let recording = block.recording {
                return recording.id == id
            } else {
                return false
            }
        }, sort: \.startMs)
        _selectedIds = State(initialValue: blockIds ?? Set(recording.blocks.filter { block in
            block.segments.contains { $0.state == .done }
        }.map(\.id)))
    }

    var body: some View {
        let rows = rows
        let selected = rows.filter { selectedIds.contains($0.block.id) }
        NavigationStack {
            Form {
                formatSection(selectedCount: selected.count)
                blocksSection(rows)
                actionSection(selected)
            }
            .navigationTitle("書き出し")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
        }
        .onChange(of: selectedIds) { reset() }
        .onChange(of: kind) { reset() }
        .onChange(of: combineTxt) { reset() }
        .onDisappear { task?.cancel() }
    }

    // MARK: - ブロック

    struct Row: Identifiable {
        let block: Block
        let title: String
        let editedMs: Int
        let segments: [Segment]

        var id: UUID { block.id }
        var doneCount: Int { segments.filter { $0.state == .done }.count }
        var unfinishedCount: Int { segments.count - doneCount }
    }

    /// 除外したブロックは、文字起こしを始めたものだけ出す
    private var rows: [Row] {
        let byBlock = Dictionary(grouping: segments) { $0.block?.id }
        return BlockService.sorted(recording).enumerated().compactMap { i, block in
            let segs = byBlock[block.id] ?? []
            guard block.status != .excluded || !segs.isEmpty else { return nil }
            return Row(block: block, title: block.title.isEmpty ? "ブロック \(i + 1)" : block.title,
                       editedMs: editedDurationMs(block: block.range, cuts: EditorService.cutRanges(block)),
                       segments: segs)
        }
    }

    private func blocksSection(_ rows: [Row]) -> some View {
        Section {
            if rows.isEmpty {
                Text("書き出せるブロックがありません").foregroundStyle(.secondary)
            }
            ForEach(rows) { row in
                Button { toggle(row.block.id) } label: {
                    BlockExportRow(row: row, isSelected: selectedIds.contains(row.block.id))
                }
                .tint(.primary)
                .disabled(isWorking)
            }
        } header: {
            HStack {
                Text("ブロック")
                Spacer()
                if !rows.isEmpty {
                    let all = selectedIds.isSuperset(of: rows.map(\.block.id))
                    Button(all ? "すべて外す" : "すべて選ぶ") {
                        selectedIds = all ? [] : Set(rows.map(\.block.id))
                    }
                    .font(.footnote)
                    .textCase(nil)
                    .disabled(isWorking)
                }
            }
        }
    }

    private func toggle(_ id: UUID) {
        if selectedIds.contains(id) { selectedIds.remove(id) } else { selectedIds.insert(id) }
    }

    // MARK: - 形式

    private func formatSection(selectedCount: Int) -> some View {
        let settings = AppSettings.current(in: modelContext)
        return Section {
            Picker("形式", selection: $kind) {
                ForEach(ExportService.Kind.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .disabled(isWorking)
            if kind.includesTxt && selectedCount > 1 {
                Toggle("txtを1つにまとめる", isOn: $combineTxt)
                    .disabled(isWorking)
            }
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                if kind.includesTxt {
                    Text("txtの時刻はカット後の時間です。カットした行と、文字起こしが終わっていない行は出しません")
                }
                if kind.includesMp3 {
                    Text("mp3はブロックごとに作ります（モノラル\(settings.mp3Kbps)kbps、カットした部分を除く）。ビットレートは設定で変えられます")
                }
            }
        }
    }

    // MARK: - 実行と共有

    private var isWorking: Bool {
        if case .working = phase { true } else { false }
    }

    @ViewBuilder
    private func actionSection(_ selected: [Row]) -> some View {
        Section {
            switch phase {
            case .idle, .failed:
                Button("書き出す", systemImage: "doc.badge.arrow.up") { start(selected) }
                    .disabled(selected.isEmpty)
                if case .failed(let message) = phase {
                    Text(message).foregroundStyle(.red)
                }
            case .working(let done, let total):
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: Double(done), total: Double(max(1, total)))
                    Text(total > 0 ? "mp3を作成中 \(done) / \(total)" : "作成中…")
                        .font(.subheadline)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Button("中止", systemImage: "xmark", role: .destructive) { task?.cancel() }
            case .finished(let output):
                finished(output)
            }
        } footer: {
            if case .idle = phase, kind.includesTxt {
                let unfinished = selected.map(\.unfinishedCount).reduce(0, +)
                if unfinished > 0 {
                    Text("文字起こしが終わっていない行が\(unfinished)件あります。txtには出ません")
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    @ViewBuilder
    private func finished(_ output: ExportService.Output) -> some View {
        ForEach(output.files, id: \.self) { file in
            Label(file.lastPathComponent, systemImage: file.pathExtension == "mp3" ? "waveform" : "doc.text")
                .lineLimit(1)
                .truncationMode(.middle)
        }
        if !output.skippedMp3.isEmpty {
            Text("すべてカットしているためmp3を作りませんでした：\(output.skippedMp3.joined(separator: "、"))")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        if !output.files.isEmpty {
            ShareLink(items: output.files) {
                Label("共有", systemImage: "square.and.arrow.up")
            }
        }
        if let txt = output.singleTxt {
            Button(copied ? "コピーしました" : "テキストをコピー", systemImage: copied ? "checkmark" : "doc.on.doc") {
                UIPasteboard.general.string = txt
                copied = true
            }
        }
    }

    private func reset() {
        guard !isWorking else { return }
        phase = .idle
        copied = false
    }

    private func start(_ selected: [Row]) {
        let request = ExportService.Request(
            recording: recording,
            blocks: selected.map(\.block),
            kind: kind,
            combineTxt: combineTxt,
            mp3Kbps: AppSettings.current(in: modelContext).mp3Kbps
        )
        let service = ExportService(context: modelContext)
        copied = false
        phase = .working(done: 0, total: 0)
        IdleTimer.set(.export, active: true)
        task = Task {
            defer { IdleTimer.set(.export, active: false) }
            do {
                let output = try await service.export(request) { done, total in
                    phase = .working(done: done, total: total)
                }
                phase = .finished(output)
            } catch is CancellationError {
                phase = .idle
            } catch {
                phase = .failed("書き出せませんでした：\(error.localizedDescription)")
            }
        }
    }
}

private struct BlockExportRow: View {
    let row: ExportView.Row
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.title2)
                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title).font(.headline)
                HStack(spacing: 8) {
                    Text("カット後 \(Format.duration(ms: row.editedMs))")
                    Text(transcriptionLabel)
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }
            Spacer()
        }
        .contentShape(Rectangle())
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var transcriptionLabel: String {
        if row.segments.isEmpty { return "未文字起こし" }
        if row.unfinishedCount == 0 { return "文字起こし済み" }
        return "文字起こし \(row.doneCount)/\(row.segments.count)"
    }
}
