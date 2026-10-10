import Foundation

/// 波形のピーク値のファイル。1バイトが1区間（20msまたは1秒）の最大振幅を表す。
/// 値は振幅の平方根を0〜255にしたもの（小さい音も見えるようにするため）。
/// ファイルはメモリマップして、必要な範囲だけ読む
public struct PeakFile: Sendable {
    /// peaks_50.bin は20msごと、peaks_1.bin は1秒ごと
    public static let msPerPeak50 = 20
    public static let msPerPeak1 = 1_000

    private let data: Data

    public init(url: URL) throws {
        data = try Data(contentsOf: url, options: .alwaysMapped)
    }

    public var count: Int { data.count }

    /// 範囲外の分は返さない
    public func read(from index: Int, count: Int) -> [UInt8] {
        let lower = min(max(0, index), data.count)
        let upper = min(max(lower, index + count), data.count)
        return [UInt8](data[data.startIndex + lower ..< data.startIndex + upper])
    }

    /// 振幅（0〜1）を保存用の値にする
    static func quantize(_ amplitude: Float) -> UInt8 {
        UInt8(min(255, (min(1, max(0, amplitude)).squareRoot() * 255).rounded()))
    }
}
