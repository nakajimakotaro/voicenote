import Foundation

public struct VADParams: Sendable, Hashable, Codable {
    /// 発話開始の確率
    public var threshold: Float
    /// 発話終了の確率（ヒステリシス）
    public var negThreshold: Float
    public var minSpeechMs: Int
    public var minSilenceMs: Int
    public var padMs: Int

    public init(threshold: Float = 0.5, negThreshold: Float = 0.35,
                minSpeechMs: Int = 250, minSilenceMs: Int = 300, padMs: Int = 100) {
        self.threshold = threshold
        self.negThreshold = negThreshold
        self.minSpeechMs = minSpeechMs
        self.minSilenceMs = minSilenceMs
        self.padMs = padMs
    }
}

public struct AudioInfo: Sendable, Hashable {
    public let durationMs: Int
    public let sampleRate: Double
    public let channels: Int
    /// ファイルのメタデータにある録音日時。なければnil
    public let recordedAt: Date?

    public init(durationMs: Int, sampleRate: Double, channels: Int, recordedAt: Date? = nil) {
        self.durationMs = durationMs
        self.sampleRate = sampleRate
        self.channels = channels
        self.recordedAt = recordedAt
    }
}

public struct AnalysisProgress: Sendable, Hashable {
    public let processedMs: Int
    public let durationMs: Int

    public init(processedMs: Int, durationMs: Int) {
        self.processedMs = processedMs
        self.durationMs = durationMs
    }
}

public enum AudioIOError: Error, Equatable {
    case noAudioTrack
    case unreadable(String)
}
