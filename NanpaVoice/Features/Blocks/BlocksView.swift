import AudioIO
import Domain
import SwiftUI

/// ブロック一覧（分割画面）。折り返しタイムラインとリストを切り替えて、
/// 結合・分割・境界の調整・除外・文字起こし対象の選択を行う
struct BlocksView: View {
    @Environment(\.modelContext) private var modelContext
    let recording: Recording
    @State private var model = BlocksViewModel()
    @State private var player = PlayerModel()
    @State private var confirmingReset = false
    @State private var adjusting: Block?

    private var service: BlockService { BlockService(context: modelContext) }

    private var selectedBlock: Block? {
        guard model.preview == nil, let id = model.selectedId else { return nil }
        return recording.blocks.first { $0.id == id }
    }

    var body: some View {
        let items = model.items(recording)
        Group {
            if let error = model.loadError {
                ContentUnavailableView(error, systemImage: "exclamationmark.triangle")
            } else if !model.loaded {
                ProgressView("読み込み中…")
            } else {
                switch model.mode {
                case .timeline: timeline(items)
                case .list: list(items)
                }
            }
        }
        .navigationTitle(recording.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .safeAreaInset(edge: .bottom) {
            if model.loaded { bottomPanel(items) }
        }
        .task { await load() }
        .onDisappear { player.stop() }
        .confirmationDialog("手で調整したブロックも作り直しますか？", isPresented: $confirmingReset, titleVisibility: .visible) {
            Button("作り直す", role: .destructive) { model.resetManual(recording, service: service) }
        } message: {
            Text("結合・分割・境界の調整・採用や除外の指定が元に戻ります。文字起こし済みのブロックは残ります")
        }
        .sheet(item: $adjusting) { block in
            BlockAdjustSheet(block: block, player: player)
        }
    }

    private func load() async {
        player.load(url: FileLayout.source(recording.id, fileName: recording.sourceFileName))
        guard let regions = await model.load(recording) else { return }
        service.ensureBlocks(recording, regions: regions)
        let p = BlockService.params(recording, settings: AppSettings.current(in: modelContext))
        model.setParams(gapMs: p.gapMs, minBlockMs: p.minBlockMs)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Picker("表示", selection: $model.mode) {
                ForEach(BlocksViewModel.Mode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 200)
        }
        ToolbarItem(placement: .primaryAction) {
            NavigationLink {
                TranscribeView(recording: recording)
            } label: {
                Label("文字起こし", systemImage: "text.bubble")
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Menu("その他", systemImage: "ellipsis.circle") {
                Picker("1行の長さ", selection: Binding(get: { model.rowMinutes }, set: { model.setRowMinutes($0) })) {
                    ForEach(BlocksViewModel.rowMinutesOptions, id: \.self) { Text("1行 \($0)分").tag($0) }
                }
                Divider()
                Button(role: .destructive) {
                    confirmingReset = true
                } label: {
                    Label("手動の調整をリセット", systemImage: "arrow.counterclockwise")
                }
            }
        }
    }

    // MARK: - タイムライン

    private func timeline(_ items: [BlockItem]) -> some View {
        let byRange = Dictionary(items.map { ($0.range, $0) }, uniquingKeysWith: { a, _ in a })
        let blockRows = Dictionary(grouping: splitIntoRows(items.map(\.range), rowMs: model.rowMs), by: \.row)
        let rows = rowCount(totalMs: recording.durationMs, rowMs: model.rowMs)
        return ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 12) {
                SplitParamsView(model: model, recording: recording, items: items, service: service)
                    .padding(.horizontal)
                LazyVStack(spacing: 6) {
                    ForEach(0 ..< rows, id: \.self) { row in
                        let pieces = (blockRows[row] ?? []).compactMap { p in
                            byRange[p.source].map { BlockPiece(piece: p, item: $0) }
                        }
                        timelineRow(row, blocks: pieces, items: items)
                    }
                }
                .padding(.horizontal, 8)
            }
            .padding(.vertical, 8)
        }
        .simultaneousGesture(MagnifyGesture().onEnded { model.zoom(by: $0.magnification) })
    }

    private func timelineRow(_ row: Int, blocks: [BlockPiece], items: [BlockItem]) -> RowTimelineView {
        let rowMs = model.rowMs
        let previewing = model.preview != nil
        var drag: ((UUID, BlockEdge, Int, Bool) -> Void)?
        if !previewing {
            drag = { id, edge, ms, ended in dragEdge(id, edge, ms, ended) }
        }
        return RowTimelineView(
            row: row,
            rowMs: rowMs,
            totalMs: recording.durationMs,
            peaks: model.peaks?.read(from: row * rowMs / 1000, count: rowMs / 1000) ?? [],
            regions: model.regionRows[row] ?? [],
            blocks: blocks,
            selectedId: previewing ? nil : model.selectedId,
            player: player,
            onTap: { ms in tapTimeline(at: ms, items: items) },
            onDragEdge: drag
        )
    }

    /// 行をタップしたら、その位置のブロックを選んでそこから再生する
    private func tapTimeline(at ms: Int, items: [BlockItem]) {
        if model.preview == nil {
            model.selectedId = items.first { $0.range.contains(ms) }?.id
        }
        player.play(from: ms)
    }

    private func dragEdge(_ id: UUID, _ edge: BlockEdge, _ ms: Int, _ ended: Bool) {
        guard let block = recording.blocks.first(where: { $0.id == id }) else { return }
        service.moveEdge(block, edge, to: ms, commit: ended)
    }

    // MARK: - リスト

    private func list(_ items: [BlockItem]) -> some View {
        List {
            Section {
                SplitParamsView(model: model, recording: recording, items: items, service: service)
            }
            Section("ブロック") {
                ForEach(items) { item in
                    BlockListRow(
                        item: item,
                        isSelected: item.id == model.selectedId,
                        isPreviewing: player.isPlaying && item.range.contains(player.positionMs),
                        onToggleTarget: { toggleTarget(item) },
                        onPreview: { preview(item) }
                    )
                    .contentShape(Rectangle())
                    .onTapGesture { model.selectedId = model.selectedId == item.id ? nil : item.id }
                    .listRowBackground(item.id == model.selectedId ? Color.accentColor.opacity(0.12) : nil)
                    .swipeActions {
                        if model.preview == nil {
                            Button(item.status == .excluded ? "戻す" : "除外") { toggleExcluded(item) }
                                .tint(item.status == .excluded ? .blue : .gray)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private func block(_ item: BlockItem) -> Block? {
        guard model.preview == nil else { return nil }
        return recording.blocks.first { $0.id == item.id }
    }

    private func toggleTarget(_ item: BlockItem) {
        guard let block = block(item) else { return }
        service.setStatus(block, block.status == .selected ? .candidate : .selected)
    }

    private func toggleExcluded(_ item: BlockItem) {
        guard let block = block(item) else { return }
        service.setStatus(block, block.status == .excluded ? .candidate : .excluded)
    }

    /// 冒頭の試聴。再生中なら止める
    private func preview(_ item: BlockItem) {
        if player.isPlaying, item.range.contains(player.positionMs) {
            player.pause()
        } else {
            player.play(from: item.range.startMs, until: item.range.endMs)
        }
    }

    // MARK: - 下部パネル

    private func bottomPanel(_ items: [BlockItem]) -> some View {
        VStack(spacing: 10) {
            if let block = selectedBlock, let item = items.first(where: { $0.id == block.id }) {
                BlockActionsView(
                    item: item,
                    block: block,
                    previous: neighbor(of: block, offset: -1),
                    next: neighbor(of: block, offset: 1),
                    player: player,
                    service: service,
                    onAdjust: { adjusting = block },
                    onClose: { model.selectedId = nil }
                )
                Divider()
            }
            PlayerBar(player: player, totalMs: recording.durationMs)
            if let error = player.errorMessage {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private func neighbor(of block: Block, offset: Int) -> Block? {
        let blocks = BlockService.sorted(recording)
        guard let index = blocks.firstIndex(where: { $0.id == block.id }) else { return nil }
        let target = index + offset
        return blocks.indices.contains(target) ? blocks[target] : nil
    }
}

/// 分割パラメータG・Lのスライダーと、ブロックの集計
private struct SplitParamsView: View {
    @Bindable var model: BlocksViewModel
    let recording: Recording
    let items: [BlockItem]
    let service: BlockService

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            slider("会話の区切り（無音）", value: $model.gapSec)
            slider("除外候補にする長さ", value: $model.minSec)
            let selected = items.filter { $0.status == .selected }
            let manual = items.filter(\.manuallyEdited).count
            HStack {
                Text("\(items.count)ブロック")
                Spacer()
                Text("採用 \(selected.count)件・\(Format.duration(ms: selected.map(\.range.durationMs).reduce(0, +)))")
            }
            .font(.subheadline)
            .monospacedDigit()
            if manual > 0 {
                Text("手で調整した\(manual)件はスライダーを動かしても残ります")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onChange(of: model.gapSec) { model.updatePreview(recording) }
        .onChange(of: model.minSec) { model.updatePreview(recording) }
    }

    private func slider(_ title: String, value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            LabeledContent(title, value: "\(Int(value.wrappedValue))秒")
                .font(.subheadline)
            Slider(value: value, in: 5 ... 120, step: 1) { editing in
                if editing {
                    model.beginEditingParams()
                } else {
                    model.commitParams(recording, service: service)
                }
            }
        }
    }
}

private struct BlockListRow: View {
    let item: BlockItem
    let isSelected: Bool
    let isPreviewing: Bool
    let onToggleTarget: () -> Void
    let onPreview: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onToggleTarget) {
                Image(systemName: item.status == .selected ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(item.status == .selected ? .green : .secondary)
            }
            .buttonStyle(.borderless)
            .disabled(item.status == .excluded)
            .accessibilityLabel(item.status == .selected ? "文字起こし対象から外す" : "文字起こし対象にする")

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.displayTitle).font(.headline)
                    if item.manuallyEdited {
                        Image(systemName: "hand.point.up.left.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("手で調整済み")
                    }
                }
                HStack(spacing: 8) {
                    Text(Format.duration(ms: item.range.startMs))
                    Text("長さ \(Format.duration(ms: item.range.durationMs))")
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }
            Spacer()
            Text(item.status.label)
                .font(.caption.bold())
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(item.status.color.opacity(0.18), in: Capsule())
                .foregroundStyle(item.status == .excluded ? .secondary : .primary)
            Button(action: onPreview) {
                Image(systemName: isPreviewing ? "stop.circle" : "play.circle")
                    .font(.title2)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(isPreviewing ? "試聴を止める" : "冒頭を試聴")
        }
        .opacity(item.status == .excluded ? 0.6 : 1)
    }
}

/// 選択中のブロックの操作
private struct BlockActionsView: View {
    let item: BlockItem
    let block: Block
    let previous: Block?
    let next: Block?
    let player: PlayerModel
    let service: BlockService
    let onAdjust: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.displayTitle).font(.headline)
                    Text("\(Format.duration(ms: block.startMs))〜\(Format.duration(ms: block.endMs))（\(Format.duration(ms: block.range.durationMs))）")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Spacer()
                Button("選択を解除", systemImage: "xmark.circle.fill", action: onClose)
                    .labelStyle(.iconOnly)
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            if item.locked {
                Text("文字起こしを始めたブロックは範囲を変えられません")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    action(block.status == .selected ? "対象から外す" : "対象にする",
                           block.status == .selected ? "checkmark.circle.fill" : "checkmark.circle") {
                        service.setStatus(block, block.status == .selected ? .candidate : .selected)
                    }
                    action(block.status == .excluded ? "除外を戻す" : "除外",
                           block.status == .excluded ? "arrow.uturn.backward.circle" : "nosign") {
                        service.setStatus(block, block.status == .excluded ? .candidate : .excluded)
                    }
                    action("試聴", "play.circle") {
                        player.play(from: block.startMs, until: block.endMs)
                    }
                    action("前と結合", "arrow.left.to.line.compact", disabled: !canMerge(previous)) {
                        if let previous { service.merge(previous, block) }
                    }
                    action("次と結合", "arrow.right.to.line.compact", disabled: !canMerge(next)) {
                        if let next { service.merge(block, next) }
                    }
                    action("再生位置で分割", "scissors", disabled: !canSplit) {
                        service.split(block, at: player.positionMs)
                    }
                    action("微調整", "slider.horizontal.3", action: onAdjust)
                }
            }
        }
    }

    private func canMerge(_ other: Block?) -> Bool {
        guard let other else { return false }
        return !item.locked && BlockService.canEditRange(other)
    }

    private var canSplit: Bool {
        !item.locked && splitRange(block.range, at: player.positionMs, minLengthMs: BlockService.minLengthMs) != nil
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

struct PlayerBar: View {
    let player: PlayerModel
    let totalMs: Int

    var body: some View {
        HStack(spacing: 20) {
            Button("10秒戻る", systemImage: "gobackward.10") { player.seek(to: player.positionMs - 10_000) }
            Button(player.isPlaying ? "一時停止" : "再生", systemImage: player.isPlaying ? "pause.fill" : "play.fill") {
                player.toggle()
            }
            .font(.title2)
            Button("10秒進む", systemImage: "goforward.10") { player.seek(to: min(totalMs, player.positionMs + 10_000)) }
            Spacer()
            Text("\(Format.duration(ms: player.positionMs)) / \(Format.duration(ms: totalMs))")
                .font(.subheadline)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .labelStyle(.iconOnly)
    }
}

/// ブロックのタイトルと境界の微調整
private struct BlockAdjustSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Bindable var block: Block
    let player: PlayerModel

    private var service: BlockService { BlockService(context: modelContext) }

    var body: some View {
        NavigationStack {
            Form {
                Section("タイトル") {
                    TextField("ブロックのタイトル", text: $block.title)
                }
                if BlockService.canEditRange(block) {
                    edgeSection("開始", edge: .start, ms: block.startMs) {
                        player.play(from: block.startMs, until: min(block.endMs, block.startMs + 5_000))
                    }
                    edgeSection("終了", edge: .end, ms: block.endMs) {
                        player.play(from: max(block.startMs, block.endMs - 5_000), until: block.endMs)
                    }
                } else {
                    Section {
                        Text("文字起こしを始めたブロックは範囲を変えられません")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("微調整")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完了") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .onDisappear {
            if block.modelContext != nil { service.save() }
        }
    }

    /// 500 → "+0.5秒"、-5000 → "-5秒"
    private static func stepLabel(_ deltaMs: Int) -> String {
        let seconds = Double(deltaMs) / 1000
        return (deltaMs > 0 ? "+" : "") + seconds.formatted(.number.precision(.fractionLength(0...1))) + "秒"
    }

    private func edgeSection(_ title: String, edge: BlockEdge, ms: Int, preview: @escaping () -> Void) -> some View {
        Section(title) {
            HStack {
                Text(Format.duration(ms: ms) + String(format: ".%01d", ms % 1000 / 100))
                    .font(.title3)
                    .monospacedDigit()
                Spacer()
                Button("試聴", systemImage: "play.circle", action: preview)
                    .labelStyle(.iconOnly)
                    .font(.title2)
            }
            HStack {
                ForEach([-5_000, -500, 500, 5_000], id: \.self) { delta in
                    Button(Self.stepLabel(delta)) {
                        service.moveEdge(block, edge, to: ms + delta)
                    }
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }
}
