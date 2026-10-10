import Domain
import Foundation
import SwiftData

enum SegmentState: String, Codable, CaseIterable {
    case pending
    case sending
    case done
    case failed
}

@Model
final class Segment {
    @Attribute(.unique) var id: UUID
    var block: Block?
    var startMs: Int
    var endMs: Int
    /// APIが返したテキスト
    var text: String
    /// 手で修正したテキスト。書き出しではこちらを優先する
    var editedText: String?
    var stateRaw: String
    /// 文字起こしに使ったモデル名
    var model: String?
    var attempts: Int

    var state: SegmentState {
        get { SegmentState(rawValue: stateRaw) ?? .pending }
        set { stateRaw = newValue.rawValue }
    }

    var range: TimeRange { TimeRange(startMs: startMs, endMs: endMs) }
    var displayText: String { editedText ?? text }

    init(id: UUID = UUID(), startMs: Int, endMs: Int) {
        self.id = id
        self.startMs = startMs
        self.endMs = endMs
        self.text = ""
        self.editedText = nil
        self.stateRaw = SegmentState.pending.rawValue
        self.model = nil
        self.attempts = 0
    }
}
