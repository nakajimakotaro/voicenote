import Foundation
import SwiftData

/// アプリ全体の設定。1件だけ持つ。APIキーはここではなくキーチェーンに保存する
@Model
final class AppSettings {
    var pricePerMinUsd: Double
    var language: String
    var gapMs: Int
    var minBlockMs: Int
    var mp3Kbps: Int

    static let transcriptionModel = "gpt-transcribe"
    static let mp3KbpsOptions = [32, 64, 128]
    /// 見積もりを円で出すときの換算レート（目安）
    static let yenPerUsd = 150.0

    init(pricePerMinUsd: Double = 0.006, language: String = "ja",
         gapMs: Int = 30_000, minBlockMs: Int = 20_000, mp3Kbps: Int = 64) {
        self.pricePerMinUsd = pricePerMinUsd
        self.language = language
        self.gapMs = gapMs
        self.minBlockMs = minBlockMs
        self.mp3Kbps = mp3Kbps
    }

    /// 保存済みの設定を返す。なければ初期値で作る
    @MainActor
    static func current(in context: ModelContext) -> AppSettings {
        if let existing = try? context.fetch(FetchDescriptor<AppSettings>()).first {
            return existing
        }
        let settings = AppSettings()
        context.insert(settings)
        try? context.save()
        return settings
    }
}
