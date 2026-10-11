import Domain
import Foundation
import SwiftData

/// エディタで取り消せる操作。変更前と変更後を両方持ち、取り消しでは前、やり直しでは後を書き込む
enum EditorEdit: Sendable {
    case cuts(blockId: UUID, before: [TimeRange], after: [TimeRange])
    /// `editedText` の変更。nilは文字起こし結果のまま
    case text(segmentId: UUID, before: String?, after: String?)
}

/// エディタからの書き込み。カットは保存時に正規化して、重なるものを結合する
@MainActor
struct EditorService {
    let context: ModelContext

    /// 正規化済みのカット
    static func cutRanges(_ block: Block) -> [TimeRange] {
        normalizeCuts(block: block.range, cuts: block.cuts.map(\.range))
    }

    /// `range` をカットに加える。変わらなければnil
    func addCut(_ range: TimeRange, to block: Block) -> EditorEdit? {
        let before = Self.cutRanges(block)
        return setCuts(normalizeCuts(block: block.range, cuts: before + [range]), of: block, before: before)
    }

    /// `range` に重なるカットを取り除く。変わらなければnil
    func removeCut(_ range: TimeRange, from block: Block) -> EditorEdit? {
        let before = Self.cutRanges(block)
        return setCuts(uncut(range, cuts: before), of: block, before: before)
    }

    /// テキストを直す。文字起こし結果と同じなら修正を消す。変わらなければnil
    func setText(_ text: String, of segment: Segment) -> EditorEdit? {
        let after: String? = text == segment.text ? nil : text
        guard after != segment.editedText else { return nil }
        let edit = EditorEdit.text(segmentId: segment.id, before: segment.editedText, after: after)
        segment.editedText = after
        save()
        return edit
    }

    /// 取り消し（`undo`）では変更前、やり直しでは変更後の状態にする
    func apply(_ edit: EditorEdit, undo: Bool) {
        switch edit {
        case let .cuts(blockId, before, after):
            guard let block = try? context.fetch(FetchDescriptor<Block>(predicate: #Predicate { $0.id == blockId })).first
            else { return }
            replaceCuts(of: block, with: undo ? before : after)
        case let .text(segmentId, before, after):
            guard let segment = try? context.fetch(FetchDescriptor<Segment>(predicate: #Predicate { $0.id == segmentId })).first
            else { return }
            segment.editedText = undo ? before : after
        }
        save()
    }

    func save() {
        try? context.save()
    }

    private func setCuts(_ after: [TimeRange], of block: Block, before: [TimeRange]) -> EditorEdit? {
        guard after != before else { return nil }
        replaceCuts(of: block, with: after)
        save()
        return .cuts(blockId: block.id, before: before, after: after)
    }

    /// 範囲が変わらないカットは残し、それ以外を入れ替える
    private func replaceCuts(of block: Block, with ranges: [TimeRange]) {
        let keep = Set(ranges)
        for cut in block.cuts where !keep.contains(cut.range) {
            context.delete(cut)
        }
        let existing = Set(block.cuts.filter { !$0.isDeleted }.map(\.range))
        for range in ranges where !existing.contains(range) {
            let cut = Cut(startMs: range.startMs, endMs: range.endMs)
            context.insert(cut)
            cut.block = block
        }
    }
}
