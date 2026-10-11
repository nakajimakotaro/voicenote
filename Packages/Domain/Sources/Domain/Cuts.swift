import Foundation

/// セグメントがカットでどれだけ隠れるか
public enum CutVisibility: Hashable, Sendable {
    /// カットに重ならない
    case full
    /// 一部がカットされている。`keptStartMs` は残った部分の開始時刻（元音声基準）
    case partial(keptStartMs: Int)
    /// すべてカットされている。txtに出さない
    case hidden
}

/// カットをブロックの範囲に収め、重なりや接しているものを結合して時刻の順に並べる
public func normalizeCuts(block: TimeRange, cuts: [TimeRange]) -> [TimeRange] {
    mergedRegions(cuts.compactMap { $0.intersection(block) })
}

/// ブロックからカットを除いた残りの区間。そのまま `renderMp3` の `ranges` になる
public func keepRanges(block: TimeRange, cuts: [TimeRange]) -> [TimeRange] {
    subtract(normalizeCuts(block: block, cuts: cuts), from: block)
}

/// 元音声の時刻から、それより前にあるカットの長さを引く。カットの中の時刻はそのカットの開始位置に寄せる。
/// `cuts` は正規化済み（重ならず時刻の順）であること
public func toEditedMs(_ t: Int, cuts: [TimeRange]) -> Int {
    var removed = 0
    for cut in cuts {
        if t <= cut.startMs { break }
        removed += min(t, cut.endMs) - cut.startMs
    }
    return t - removed
}

/// セグメントがカットでどれだけ隠れるか。`cuts` は正規化済みであること
public func visibility(of seg: TimeRange, cuts: [TimeRange]) -> CutVisibility {
    let kept = subtract(cuts, from: seg)
    guard let first = kept.first else { return .hidden }
    return kept == [seg] ? .full : .partial(keptStartMs: first.startMs)
}

/// カットから `range` の部分を取り除く（カットを戻す）。結果は正規化済み
public func uncut(_ range: TimeRange, cuts: [TimeRange]) -> [TimeRange] {
    mergedRegions(cuts).flatMap { subtract([range], from: $0) }
}

/// `ms` を含むカット。`cuts` は正規化済みであること
public func cut(containing ms: Int, in cuts: [TimeRange]) -> TimeRange? {
    indexOfRange(containing: ms, in: cuts).map { cuts[$0] }
}

/// `range` から `holes`（正規化済み）を除いた残り
func subtract(_ holes: [TimeRange], from range: TimeRange) -> [TimeRange] {
    var result: [TimeRange] = []
    var start = range.startMs
    for hole in holes where hole.overlaps(range) {
        if hole.startMs > start { result.append(TimeRange(startMs: start, endMs: hole.startMs)) }
        start = max(start, hole.endMs)
    }
    if start < range.endMs { result.append(TimeRange(startMs: start, endMs: range.endMs)) }
    return result
}
