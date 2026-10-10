import Foundation

/// 折り返しタイムラインの1行に収まる区間の一部。時刻は元音声基準のまま
public struct RowPiece: Hashable, Sendable {
    public let row: Int
    public let startMs: Int
    public let endMs: Int
    /// 分ける前の区間
    public let source: TimeRange

    public init(row: Int, startMs: Int, endMs: Int, source: TimeRange) {
        self.row = row
        self.startMs = startMs
        self.endMs = endMs
        self.source = source
    }

    /// 区間の先頭がこの行にあるか
    public var containsStart: Bool { startMs == source.startMs }
    /// 区間の末尾がこの行にあるか
    public var containsEnd: Bool { endMs == source.endMs }
}

/// 区間を `rowMs` ごとの行に分ける。行をまたぐ区間は、行の境目で切って次の行に続ける
public func splitIntoRows(_ ranges: [TimeRange], rowMs: Int) -> [RowPiece] {
    precondition(rowMs > 0)
    var pieces: [RowPiece] = []
    for range in ranges where !range.isEmpty {
        var start = max(0, range.startMs)
        while start < range.endMs {
            let row = start / rowMs
            let end = min(range.endMs, (row + 1) * rowMs)
            pieces.append(RowPiece(row: row, startMs: start, endMs: end, source: range))
            start = end
        }
    }
    return pieces
}

/// 全体を `rowMs` ごとに折り返したときの行数
public func rowCount(totalMs: Int, rowMs: Int) -> Int {
    precondition(rowMs > 0)
    return max(1, (totalMs + rowMs - 1) / rowMs)
}
