import Domain
import SwiftData
import SwiftUI

/// エディタ（ブロック詳細）。上に波形、下にセグメントごとのテキストを並べ、再生と連動させる。
/// カット、取り消し / やり直し、テキストの修正、タイトルとメモ、倍速を扱う
struct EditorView: View {
    @Environment(\.modelContext) private var modelContext
    let block: Block
    /// 文字起こしは別のコンテキストで保存されるので、関連ではなく@Queryで購読する
    @Query private var segments: [Segment]
    @Query private var cutModels: [Cut]
    @State private var model: EditorModel
    @State private var player = PlayerModel()
    @State private var editingSegment: Segment?
    @State private var showingInfo = false

    init(block: Block) {
        self.block = block
        let id = block.id
        _segments = Query(filter: #Predicate<Segment> { segment in
            if let block = segment.block { return block.id == id } else { return false }
        }, sort: \.startMs)
        _cutModels = Query(filter: #Predicate<Cut> { cut in
            if let block = cut.block { return block.id == id } else { return false }
        }, sort: \.startMs)
        _model = State(initialValue: EditorModel(block: block.range))
    }

    private var service: EditorService { EditorService(context: modelContext) }

    private var displayTitle: String {
        guard block.title.isEmpty else { return block.title }
        let number = block.recording.flatMap { BlockService.sorted($0).firstIndex { $0.id == block.id } }
        return number.map { "ブロック \($0 + 1)" } ?? "ブロック"
    }

    var body: some View {
        let cuts = normalizeCuts(block: block.range, cuts: cutModels.map(\.range))
        VStack(spacing: 0) {
            waveform(cuts)
            Divider()
            segmentList(cuts)
        }
        .navigationTitle(displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .safeAreaInset(edge: .bottom) { bottomPanel(cuts) }
        .background {
            PlaybackFollower(player: player, model: model, ranges: segments.map(\.range), ids: segments.map(\.id))
        }
        .task { await load(cuts) }
        .onChange(of: cuts) { player.setCuts($1) }
        .onDisappear { player.stop() }
        .sheet(item: $editingSegment) { segment in
            let hidden = visibility(of: segment.range, cuts: cuts) == .hidden
            SegmentTextSheet(segment: segment, onPlay: hidden ? nil : { play(segment.range) }) { text in
                model.record(service.setText(text, of: segment))
            }
        }
        .sheet(isPresented: $showingInfo) {
            BlockInfoSheet(block: block)
        }
    }

    private func load(_ cuts: [TimeRange]) async {
        guard let recording = block.recording else { return }
        player.load(url: FileLayout.source(recording.id, fileName: recording.sourceFileName))
        player.setCuts(cuts)
        if !block.range.contains(player.positionMs) { player.seek(to: block.startMs) }
        await model.loadPeaks(recordingId: recording.id)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button("取り消す", systemImage: "arrow.uturn.backward") { model.undo(service) }
                .disabled(!model.history.canUndo)
            Button("やり直す", systemImage: "arrow.uturn.forward") { model.redo(service) }
                .disabled(!model.history.canRedo)
            Button("タイトルとメモ", systemImage: "square.and.pencil") { showingInfo = true }
        }
    }

    // MARK: - 波形

    private func waveform(_ cuts: [TimeRange]) -> some View {
        VStack(spacing: 8) {
            WaveformView(
                peaks: model.peaks,
                peaksStartMs: model.peaksStartMs,
                viewRange: model.viewRange,
                cuts: cuts,
                selection: model.selection?.range,
                boundaries: segments.dropFirst().map(\.startMs),
                player: player,
                onTap: { tapWaveform(at: $0, cuts: cuts) },
                onDrag: { model.drag(from: $0, to: $1, ended: $2) },
                onMagnify: { model.magnify(by: $0, ended: $1) }
            )
            .frame(height: 110)
            HStack {
                Toggle(isOn: $model.selectingRange) {
                    Label("範囲を選ぶ", systemImage: "selection.pin.in.out")
                }
                .toggleStyle(.button)
                Spacer()
                if model.isZoomed {
                    Button("全体を表示", systemImage: "arrow.down.right.and.arrow.up.left") { model.showWholeBlock() }
                }
            }
            .font(.subheadline)
            .controlSize(.small)
            .buttonStyle(.bordered)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }

    /// タップした位置から再生する。カットの上なら、そのカットを選ぶ
    private func tapWaveform(at fraction: CGFloat, cuts: [TimeRange]) {
        let ms = model.ms(atFraction: fraction)
        if model.selectingRange {
            model.selection = nil
            return
        }
        model.selection = cut(containing: ms, in: cuts).map { .range($0) }
        player.play(from: ms, until: block.endMs)
    }

    // MARK: - テキスト

    private func segmentList(_ cuts: [TimeRange]) -> some View {
        ScrollViewReader { proxy in
            List {
                if segments.isEmpty {
                    Text("まだ文字起こししていません。波形でカットはできます")
                        .foregroundStyle(.secondary)
                }
                ForEach(segments) { segment in
                    let vis = visibility(of: segment.range, cuts: cuts)
                    SegmentEditRow(segment: segment, visibility: vis, timeLabel: timeLabel(segment, vis, cuts))
                        .id(segment.id)
                        .contentShape(Rectangle())
                        .onTapGesture { selectSegment(segment) }
                        .listRowBackground(rowBackground(segment))
                        .swipeActions(edge: .trailing) {
                            if vis == .hidden {
                                Button("戻す", systemImage: "arrow.uturn.backward") { removeCut(segment.range) }
                                    .tint(.blue)
                            } else {
                                Button("カット", systemImage: "scissors") { addCut(segment.range) }
                                    .tint(.gray)
                            }
                        }
                        .swipeActions(edge: .leading) {
                            if segment.state == .done {
                                Button("修正", systemImage: "pencil") { editingSegment = segment }
                                    .tint(.orange)
                            }
                        }
                }
            }
            .listStyle(.plain)
            .onChange(of: model.currentSegmentId) { _, id in
                guard player.isPlaying, let id else { return }
                withAnimation { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }

    /// カット後の時刻（ブロックの先頭から）。txtとmp3の時刻と揃う
    private func timeLabel(_ segment: Segment, _ vis: CutVisibility, _ cuts: [TimeRange]) -> String? {
        let start: Int
        switch vis {
        case .full: start = segment.startMs
        case .partial(let kept): start = kept
        case .hidden: return nil
        }
        return Format.duration(ms: toEditedMs(start, cuts: cuts) - block.startMs)
    }

    private func rowBackground(_ segment: Segment) -> Color? {
        if case .segment(segment.id, _) = model.selection { return .accentColor.opacity(0.18) }
        if segment.id == model.currentSegmentId { return .yellow.opacity(0.18) }
        return nil
    }

    /// 行をタップしたら選んで、その位置から再生する
    private func selectSegment(_ segment: Segment) {
        model.selection = .segment(segment.id, segment.range)
        player.play(from: segment.startMs, until: block.endMs)
    }

    private func play(_ range: TimeRange) {
        player.play(from: range.startMs, until: range.endMs)
    }

    private func addCut(_ range: TimeRange) {
        model.record(service.addCut(range, to: block))
    }

    private func removeCut(_ range: TimeRange) {
        model.record(service.removeCut(range, from: block))
    }

    // MARK: - 下部パネル

    private func bottomPanel(_ cuts: [TimeRange]) -> some View {
        VStack(spacing: 10) {
            if let selection = model.selection {
                selectionBar(selection, cuts: cuts)
                Divider()
            }
            EditorPlayerBar(player: player, block: block.range, cuts: cuts)
            if let error = player.errorMessage {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private func selectionBar(_ selection: EditorModel.Selection, cuts: [TimeRange]) -> some View {
        let range = selection.range
        let segment: Segment? = if case .segment(let id, _) = selection { segments.first { $0.id == id } } else { nil }
        let fullyCut = visibility(of: range, cuts: cuts) == .hidden
        let touchesCut = cuts.contains { $0.overlaps(range) }
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(segment == nil ? "選択した範囲" : "選択した行")
                    .font(.subheadline.bold())
                Text(Self.lengthLabel(range.durationMs))
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Spacer()
                Button("選択を解除", systemImage: "xmark.circle.fill") { model.selection = nil }
                    .labelStyle(.iconOnly)
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 4) {
                action("試聴", "play.circle", disabled: fullyCut) { play(range) }
                action("カット", "scissors", disabled: fullyCut) { addCut(range) }
                action("カットを戻す", "arrow.uturn.backward.circle", disabled: !touchesCut) { removeCut(range) }
                if let segment {
                    action("テキスト修正", "pencil", disabled: segment.state != .done) { editingSegment = segment }
                }
            }
        }
    }

    /// 8400 → "8.4秒"、95000 → "1:35"
    private static func lengthLabel(_ ms: Int) -> String {
        ms < 60_000
            ? (Double(ms) / 1000).formatted(.number.precision(.fractionLength(1))) + "秒"
            : Format.duration(ms: ms)
    }

    private func action(_ title: String, _ icon: String, disabled: Bool = false,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.title3)
                Text(title).font(.caption2)
            }
            .frame(minWidth: 64)
            .padding(.vertical, 4)
        }
        .buttonStyle(.borderless)
        .disabled(disabled)
    }
}

/// 再生位置を見て、ハイライトするセグメントと波形の表示範囲を更新する。
/// 位置を読むのはこのビューだけなので、再生中にエディタ全体が描き直されない
private struct PlaybackFollower: View {
    let player: PlayerModel
    let model: EditorModel
    let ranges: [TimeRange]
    let ids: [UUID]

    var body: some View {
        Color.clear.onChange(of: player.positionMs, initial: true) { _, ms in
            model.follow(ms, isPlaying: player.isPlaying, segments: ranges, ids: ids)
        }
    }
}

private struct SegmentEditRow: View {
    let segment: Segment
    let visibility: CutVisibility
    /// カット後の開始時刻。すべてカットされていればnil
    let timeLabel: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(timeLabel ?? "カット")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .leading)
            content
                .frame(maxWidth: .infinity, alignment: .leading)
            if segment.editedText != nil {
                Image(systemName: "pencil")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .accessibilityLabel("修正済み")
            }
            if case .partial = visibility {
                Image(systemName: "scissors")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("一部カット")
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var content: some View {
        switch segment.state {
        case .done:
            let text = segment.displayText
            Text(text.isEmpty ? "（発話なし）" : text)
                .strikethrough(visibility == .hidden)
                .foregroundStyle(text.isEmpty || visibility == .hidden ? .secondary : .primary)
        case .failed:
            Text("文字起こしに失敗しました").foregroundStyle(.red)
        case .sending:
            Text("送信中…").foregroundStyle(.secondary)
        case .pending:
            Text("未送信").foregroundStyle(.secondary)
        }
    }
}

/// 再生操作、カット後の位置と長さ、倍速、カットを飛ばすかどうか
private struct EditorPlayerBar: View {
    @Bindable var player: PlayerModel
    let block: TimeRange
    let cuts: [TimeRange]

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 20) {
                Button("5秒戻る", systemImage: "gobackward.5") { seek(by: -5_000) }
                Button(player.isPlaying ? "一時停止" : "再生", systemImage: player.isPlaying ? "pause.fill" : "play.fill") {
                    toggle()
                }
                .font(.title2)
                Button("5秒進む", systemImage: "goforward.5") { seek(by: 5_000) }
                Spacer()
                Text("\(Format.duration(ms: edited(player.positionMs))) / \(Format.duration(ms: edited(block.endMs)))")
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .labelStyle(.iconOnly)
            HStack {
                Picker("再生速度", selection: $player.rate) {
                    ForEach(PlayerModel.rates, id: \.self) { rate in
                        Text(rate.formatted(.number.precision(.fractionLength(1 ... 2))) + "倍").tag(rate)
                    }
                }
                .pickerStyle(.menu)
                Spacer()
            }
        }
    }

    /// ブロックの先頭からの、カット後の時刻
    private func edited(_ ms: Int) -> Int {
        toEditedMs(min(max(ms, block.startMs), block.endMs), cuts: cuts) - block.startMs
    }

    private func toggle() {
        if player.isPlaying {
            player.pause()
            return
        }
        let ms = player.positionMs
        let start = block.contains(ms) && ms < block.endMs - 100 ? ms : block.startMs
        player.play(from: start, until: block.endMs)
    }

    private func seek(by delta: Int) {
        player.seek(to: min(max(player.positionMs + delta, block.startMs), block.endMs))
    }
}

/// セグメントのテキストの修正。保存した時点で1つの操作として取り消せる
private struct SegmentTextSheet: View {
    @Environment(\.dismiss) private var dismiss
    let segment: Segment
    /// すべてカットされた行ではnil（再生してもカットを飛ばすので何も鳴らない）
    let onPlay: (() -> Void)?
    let onSave: (String) -> Void
    @State private var text: String

    init(segment: Segment, onPlay: (() -> Void)?, onSave: @escaping (String) -> Void) {
        self.segment = segment
        self.onPlay = onPlay
        self.onSave = onSave
        _text = State(initialValue: segment.displayText)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $text)
                        .frame(minHeight: 120)
                } footer: {
                    if text != segment.text {
                        Text("文字起こし結果：\(segment.text)")
                    }
                }
                Section {
                    if let onPlay {
                        Button("この部分を再生", systemImage: "play.circle", action: onPlay)
                    }
                    if text != segment.text {
                        Button("文字起こし結果に戻す", systemImage: "arrow.uturn.backward") { text = segment.text }
                    }
                }
            }
            .navigationTitle("テキストを修正")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        onSave(text)
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// ブロックのタイトルとメモ。取り消しの対象にはしない
private struct BlockInfoSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Bindable var block: Block

    var body: some View {
        NavigationStack {
            Form {
                Section("タイトル") {
                    TextField("ブロックのタイトル", text: $block.title)
                }
                Section("メモ") {
                    TextEditor(text: $block.memo)
                        .frame(minHeight: 160)
                }
            }
            .navigationTitle("タイトルとメモ")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完了") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .onDisappear { try? modelContext.save() }
    }
}
