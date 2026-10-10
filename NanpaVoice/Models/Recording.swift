import Foundation
import SwiftData

enum AnalysisState: String, Codable, CaseIterable {
    case pending
    case running
    case done
    case error
}

@Model
final class Recording {
    @Attribute(.unique) var id: UUID
    var name: String
    /// `recordings/{id}/` に置いた元ファイル名（例：source.m4a）
    var sourceFileName: String
    var durationMs: Int
    var createdAt: Date
    var analysisStateRaw: String
    /// 表示用。再開位置は checkpoint.json を正とする
    var analysisProgressMs: Int
    /// 解析に失敗したときの理由（画面表示用）
    var analysisErrorMessage: String?

    @Relationship(deleteRule: .cascade, inverse: \Block.recording)
    var blocks: [Block] = []

    var analysisState: AnalysisState {
        get { AnalysisState(rawValue: analysisStateRaw) ?? .pending }
        set { analysisStateRaw = newValue.rawValue }
    }

    /// - Parameter createdAt: 録音日。わかればファイルのメタデータの日時を入れる
    init(id: UUID = UUID(), name: String, sourceFileName: String, durationMs: Int, createdAt: Date = .now) {
        self.id = id
        self.name = name
        self.sourceFileName = sourceFileName
        self.durationMs = durationMs
        self.createdAt = createdAt
        self.analysisStateRaw = AnalysisState.pending.rawValue
        self.analysisProgressMs = 0
    }
}
