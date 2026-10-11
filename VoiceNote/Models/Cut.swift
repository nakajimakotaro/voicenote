import Domain
import Foundation
import SwiftData

/// 重なるカットは保存時に結合する（Domainの normalizeCuts を通す）
@Model
final class Cut {
    @Attribute(.unique) var id: UUID
    var block: Block?
    var startMs: Int
    var endMs: Int

    var range: TimeRange { TimeRange(startMs: startMs, endMs: endMs) }

    init(id: UUID = UUID(), startMs: Int, endMs: Int) {
        self.id = id
        self.startMs = startMs
        self.endMs = endMs
    }
}
