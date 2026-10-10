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

    /// 0.123 → "$0.12"、0.004 → "$0.004"（1セント未満は桁を増やす）
    static func usd(_ value: Double) -> String {
        let digits = value > 0 && value < 0.01 ? 3 : 2
        return "$" + value.formatted(.number.precision(.fractionLength(digits)))
    }

    /// 18.4 → "18円"、0.3 → "1円未満"
    static func yen(_ value: Double) -> String {
        value > 0 && value < 1 ? "1円未満" : "\(Int(value.rounded()))円"
    }
}
