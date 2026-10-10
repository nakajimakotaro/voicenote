import Foundation

/// 送信する音声の合計時間から料金の目安を出す（ドル）
public func estimateUsd(totalMs: Int, pricePerMinUsd: Double) -> Double {
    Double(max(0, totalMs)) / 60_000 * pricePerMinUsd
}
