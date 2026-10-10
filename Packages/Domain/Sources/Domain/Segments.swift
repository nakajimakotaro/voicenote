import Foundation

/// ブロックを文字起こしの送信単位（セグメント）に分ける。
///
/// 1. ブロック内の発話区間を前から詰め、セグメントの長さが `maxMs` を超える手前で区切る
/// 2. 区切りは発話区間のあいだの無音の中点にする。最初のセグメントはブロックの先頭から、
///    最後はブロックの末尾までとし、ブロック全体を隙間なく覆う
/// 3. 1つの発話が `maxMs` より長い場合は、後半の範囲（`maxMs` の半分〜`maxMs`）で最も静かな点
///    （`quietestPoint`）で切る。なければ `maxMs` の位置で切る
///
/// 無音の中点で区切るので、長い無音の前後のセグメントは `maxMs` を少し超えることがある。
/// 発話区間がなければ、ブロック全体を1つの長い発話として扱う。結果は時刻の順に並ぶ
public func buildSegments(block: TimeRange, regions: [TimeRange], maxMs: Int,
                          quietestPoint: ((TimeRange) -> Int)?) -> [TimeRange] {
    precondition(maxMs > 0)
    guard !block.isEmpty else { return [] }

    var speech = mergedRegions(regions.compactMap { $0.intersection(block) })
    if speech.isEmpty { speech = [block] }
    let pieces = speech.flatMap { splitLongRegion($0, maxMs: maxMs, quietestPoint: quietestPoint) }

    var bounds = [block.startMs]
    var prevEnd: Int?
    for piece in pieces {
        if let prevEnd, piece.endMs - bounds[bounds.count - 1] > maxMs {
            bounds.append((prevEnd + piece.startMs) / 2)
        }
        prevEnd = piece.endMs
    }
    bounds.append(block.endMs)
    return zip(bounds, bounds.dropFirst())
        .map { TimeRange(startMs: $0, endMs: $1) }
        .filter { !$0.isEmpty }
}

/// 重なりや接している区間をつなげ、時刻の順に並べる
func mergedRegions(_ regions: [TimeRange]) -> [TimeRange] {
    var result: [TimeRange] = []
    for r in regions.sorted(by: { $0.startMs < $1.startMs }) where !r.isEmpty {
        if let last = result.last, r.startMs <= last.endMs {
            result[result.count - 1].endMs = max(last.endMs, r.endMs)
        } else {
            result.append(r)
        }
    }
    return result
}

/// `maxMs` より長い発話を、隙間なく接する `maxMs` 以下の区間に分ける
func splitLongRegion(_ region: TimeRange, maxMs: Int, quietestPoint: ((TimeRange) -> Int)?) -> [TimeRange] {
    var result: [TimeRange] = []
    var start = region.startMs
    while region.endMs - start > maxMs {
        let window = TimeRange(startMs: start + maxMs / 2, endMs: start + maxMs)
        let cut = min(max(quietestPoint?(window) ?? window.endMs, window.startMs), window.endMs)
        // maxMsが1msのような極端な値でも必ず前に進む
        let next = max(cut, start + 1)
        result.append(TimeRange(startMs: start, endMs: next))
        start = next
    }
    result.append(TimeRange(startMs: start, endMs: region.endMs))
    return result
}
