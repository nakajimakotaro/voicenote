import Domain
import Foundation
import SwiftData

/// ブロックの作成と編集。判断はDomainの関数に任せ、ここはSwiftDataとの変換と保存だけを行う。
/// 手で操作したブロックは `manuallyEdited` にして、分割パラメータを変えても作り直さない
@MainActor
struct BlockService {
    /// 分割や境界の調整で、これより短いブロックは作らない
    static let minLengthMs = 1_000

    let context: ModelContext

    /// 開始時刻の順に並べたブロック
    static func sorted(_ recording: Recording) -> [Block] {
        recording.blocks.sorted { $0.startMs < $1.startMs }
    }

    /// 文字起こしを始めたブロックは、セグメントの時刻がずれるので範囲を変えない
    static func canEditRange(_ block: Block) -> Bool {
        block.segments.isEmpty
    }

    /// 作り直しても残すブロック。`keepManual` がfalseでも、文字起こしを始めたものは残す
    static func fixedDrafts(_ recording: Recording, keepManual: Bool = true) -> [BlockDraft] {
        recording.blocks
            .filter { (keepManual && $0.manuallyEdited) || !canEditRange($0) }
            .map { BlockDraft(range: $0.range, status: $0.status, manuallyEdited: true) }
    }

    /// 分割パラメータ。録音ごとに選んだ値がなければ設定の初期値
    static func params(_ recording: Recording, settings: AppSettings) -> (gapMs: Int, minBlockMs: Int) {
        (recording.blockGapMs ?? settings.gapMs, recording.blockMinMs ?? settings.minBlockMs)
    }

    /// 解析が終わってまだブロックがなければ作る
    func ensureBlocks(_ recording: Recording, regions: [TimeRange]) {
        guard recording.blocks.isEmpty else { return }
        let p = Self.params(recording, settings: AppSettings.current(in: context))
        regenerate(recording, regions: regions, gapMs: p.gapMs, minBlockMs: p.minBlockMs)
    }

    /// 分割パラメータでブロックを作り直す。手で操作したブロックは `keepManual` なら残す
    func regenerate(_ recording: Recording, regions: [TimeRange], gapMs: Int, minBlockMs: Int,
                    keepManual: Bool = true) {
        recording.blockGapMs = gapMs
        recording.blockMinMs = minBlockMs
        let fixed = Self.fixedDrafts(recording, keepManual: keepManual)
        for block in recording.blocks where !fixed.contains(where: { $0.range == block.range }) {
            context.delete(block)
        }
        let drafts = buildBlocks(regions: regions, gapMs: gapMs, minBlockMs: minBlockMs, manual: fixed)
        for draft in drafts where !draft.manuallyEdited {
            let block = Block(startMs: draft.range.startMs, endMs: draft.range.endMs, status: draft.status)
            context.insert(block)
            block.recording = recording
        }
        save()
    }

    func setStatus(_ block: Block, _ status: BlockStatus) {
        block.status = status
        block.manuallyEdited = true
        save()
    }

    /// 隣り合う2つを1つにする。あいだの無音も含める。`first` を残して `second` を消す
    func merge(_ first: Block, _ second: Block) {
        guard Self.canEditRange(first), Self.canEditRange(second) else { return }
        let (a, b) = first.startMs <= second.startMs ? (first, second) : (second, first)
        a.endMs = max(a.endMs, b.endMs)
        a.startMs = min(a.startMs, b.startMs)
        if a.status != .selected { a.status = b.status == .selected ? .selected : .candidate }
        a.title = [a.title, b.title].filter { !$0.isEmpty }.joined(separator: " / ")
        a.memo = [a.memo, b.memo].filter { !$0.isEmpty }.joined(separator: "\n")
        a.manuallyEdited = true
        context.delete(b)
        save()
    }

    /// `ms` の位置で2つに分ける。前半は元のブロック、後半は新しいブロックになる
    @discardableResult
    func split(_ block: Block, at ms: Int) -> Block? {
        guard Self.canEditRange(block),
              let (head, tail) = splitRange(block.range, at: ms, minLengthMs: Self.minLengthMs),
              let recording = block.recording else { return nil }
        block.endMs = head.endMs
        block.manuallyEdited = true
        let newBlock = Block(startMs: tail.startMs, endMs: tail.endMs, status: block.status, manuallyEdited: true)
        context.insert(newBlock)
        newBlock.recording = recording
        save()
        return newBlock
    }

    /// 端を動かせる範囲
    func limits(_ block: Block, edge: BlockEdge) -> ClosedRange<Int> {
        guard let recording = block.recording else { return block.startMs...block.endMs }
        let blocks = Self.sorted(recording)
        guard let index = blocks.firstIndex(where: { $0.id == block.id }) else { return block.startMs...block.endMs }
        return boundaryLimits(of: index, edge: edge, in: blocks.map(\.range),
                              totalMs: recording.durationMs, minLengthMs: Self.minLengthMs)
    }

    /// 端を動かす。動かせる範囲に収める。ドラッグ中は `commit` をfalseにして、離したときに保存する
    func moveEdge(_ block: Block, _ edge: BlockEdge, to ms: Int, commit: Bool = true) {
        guard Self.canEditRange(block) else { return }
        let clamped = min(max(ms, limits(block, edge: edge).lowerBound), limits(block, edge: edge).upperBound)
        switch edge {
        case .start: if block.startMs != clamped { block.startMs = clamped }
        case .end: if block.endMs != clamped { block.endMs = clamped }
        }
        block.manuallyEdited = true
        if commit { save() }
    }

    func save() {
        try? context.save()
    }
}
