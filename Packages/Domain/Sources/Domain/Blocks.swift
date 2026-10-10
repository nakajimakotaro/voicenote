import Foundation

/// 発話区間から会話ブロックを作る。
///
/// 1. 発話区間を時刻順に並べ、間の無音が `gapMs` 未満ならつなげて1ブロックにする
/// 2. 長さが `minBlockMs` 未満のブロックは `excluded`、それ以外は `candidate` にする
/// 3. 手で編集したブロック（`manual`）はそのまま残し、そこに重なる発話区間は自動計算から外す。
///    手動のブロックをまたいでつなげないので、自動のブロックが手動のものに重なることはない
///
/// 結果は開始時刻の順に並ぶ
public func buildBlocks(regions: [TimeRange], gapMs: Int, minBlockMs: Int, manual: [BlockDraft]) -> [BlockDraft] {
    let fixed = manual.map(\.range).sorted { $0.startMs < $1.startMs }
    var result = manual
    var current: TimeRange?

    func flush() {
        guard let c = current else { return }
        result.append(BlockDraft(range: c, status: c.durationMs < minBlockMs ? .excluded : .candidate,
                                 manuallyEdited: false))
        current = nil
    }

    for region in regions.sorted(by: { $0.startMs < $1.startMs }) where !region.isEmpty {
        if fixed.contains(where: { $0.overlaps(region) }) { continue }
        guard let c = current else {
            current = region
            continue
        }
        let separated = fixed.contains { $0.startMs >= c.endMs && $0.endMs <= region.startMs }
        if separated || region.startMs - c.endMs >= gapMs {
            flush()
            current = region
        } else {
            current = TimeRange(startMs: c.startMs, endMs: max(c.endMs, region.endMs))
        }
    }
    flush()
    return result.sorted { $0.range.startMs < $1.range.startMs }
}

public enum BlockEdge: Hashable, Sendable {
    case start
    case end
}

/// ブロックの端を動かせる範囲。隣のブロックに重ならず、ブロックが `minLengthMs` より短くならない。
/// `blocks` は開始時刻の順に並んだ、重ならない区間
public func boundaryLimits(of index: Int, edge: BlockEdge, in blocks: [TimeRange],
                           totalMs: Int, minLengthMs: Int) -> ClosedRange<Int> {
    let block = blocks[index]
    let lower: Int, upper: Int
    switch edge {
    case .start:
        lower = index > 0 ? blocks[index - 1].endMs : 0
        upper = block.endMs - minLengthMs
    case .end:
        lower = block.startMs + minLengthMs
        upper = index + 1 < blocks.count ? blocks[index + 1].startMs : totalMs
    }
    let current = edge == .start ? block.startMs : block.endMs
    guard lower <= upper else { return current...current }
    return lower...upper
}

/// `at` の位置で2つに分ける。どちらかが `minLengthMs` より短くなるならnil
public func splitRange(_ range: TimeRange, at ms: Int, minLengthMs: Int) -> (TimeRange, TimeRange)? {
    guard ms - range.startMs >= minLengthMs, range.endMs - ms >= minLengthMs else { return nil }
    return (TimeRange(startMs: range.startMs, endMs: ms), TimeRange(startMs: ms, endMs: range.endMs))
}
