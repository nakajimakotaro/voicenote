import Foundation

/// 元音声の先頭からの時刻（整数ミリ秒）で表した半開区間 [startMs, endMs)
public struct TimeRange: Hashable, Sendable, Codable {
    public var startMs: Int
    public var endMs: Int

    public init(startMs: Int, endMs: Int) {
        self.startMs = startMs
        self.endMs = endMs
    }

    public var durationMs: Int { max(0, endMs - startMs) }
    public var isEmpty: Bool { endMs <= startMs }

    public func contains(_ ms: Int) -> Bool { startMs <= ms && ms < endMs }

    /// 共有する長さが1ms以上あるか（接しているだけでは重ならない）
    public func overlaps(_ other: TimeRange) -> Bool {
        startMs < other.endMs && other.startMs < endMs
    }

    /// 重なる部分。重ならなければnil
    public func intersection(_ other: TimeRange) -> TimeRange? {
        let r = TimeRange(startMs: max(startMs, other.startMs), endMs: min(endMs, other.endMs))
        return r.isEmpty ? nil : r
    }
}

public enum BlockStatus: String, Hashable, Sendable, Codable, CaseIterable {
    case candidate
    case selected
    case excluded
}

/// SwiftDataのモデルではなく、Domain専用の値型。Servicesが相互に変換する
public struct BlockDraft: Hashable, Sendable {
    public var range: TimeRange
    public var status: BlockStatus
    public var manuallyEdited: Bool

    public init(range: TimeRange, status: BlockStatus, manuallyEdited: Bool) {
        self.range = range
        self.status = status
        self.manuallyEdited = manuallyEdited
    }
}
