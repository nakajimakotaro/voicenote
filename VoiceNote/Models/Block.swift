import Domain
import Foundation
import SwiftData

@Model
final class Block {
    @Attribute(.unique) var id: UUID
    var recording: Recording?
    var startMs: Int
    var endMs: Int
    var title: String
    var statusRaw: String
    var memo: String
    var manuallyEdited: Bool

    @Relationship(deleteRule: .cascade, inverse: \Segment.block)
    var segments: [Segment] = []

    @Relationship(deleteRule: .cascade, inverse: \Cut.block)
    var cuts: [Cut] = []

    var status: BlockStatus {
        get { BlockStatus(rawValue: statusRaw) ?? .candidate }
        set { statusRaw = newValue.rawValue }
    }

    var range: TimeRange { TimeRange(startMs: startMs, endMs: endMs) }

    init(id: UUID = UUID(), startMs: Int, endMs: Int, title: String = "", status: BlockStatus = .candidate,
         memo: String = "", manuallyEdited: Bool = false) {
        self.id = id
        self.startMs = startMs
        self.endMs = endMs
        self.title = title
        self.statusRaw = status.rawValue
        self.memo = memo
        self.manuallyEdited = manuallyEdited
    }
}
