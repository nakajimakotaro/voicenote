import Foundation

enum Format {
    /// 3725000 → "1:02:05"、65000 → "1:05"
    static func duration(ms: Int) -> String {
        let total = max(0, ms) / 1000
        let h = total / 3600, m = total / 60 % 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// 残り時間の目安。90秒 → "2分"、40秒 → "1分"、2時間5分 → "2時間5分"
    static func remaining(_ d: Duration) -> String {
        let minutes = max(1, Int((Double(d.components.seconds) / 60).rounded()))
        return minutes >= 60 ? "\(minutes / 60)時間\(minutes % 60)分" : "\(minutes)分"
    }
}
