import AudioIO
import Domain
import Foundation
import Observation

/// エディタの一時的な状態。選択、波形の表示範囲、取り消し履歴を持つ。
/// 履歴はこのモデルと一緒に消えるので、エディタを閉じると消える
@MainActor
@Observable
final class EditorModel {
    enum Selection: Equatable {
        case segment(UUID, TimeRange)
        /// 波形のドラッグや、タップしたカット
        case range(TimeRange)

        var range: TimeRange {
            switch self {
            case .segment(_, let range), .range(let range): range
            }
        }
    }

    /// 波形で最も拡大したときに見える長さ
    static let minSpanMs = 5_000

    let block: TimeRange
    var selection: Selection?
    /// オンのあいだは、波形のドラッグで範囲を選ぶ。オフならドラッグで表示範囲を動かす
    var selectingRange = false
    /// 再生位置にあるセグメント
    private(set) var currentSegmentId: UUID?

    private(set) var history = EditHistory<EditorEdit>()
    private(set) var peaks: [UInt8] = []
    /// `peaks` の先頭の時刻
    private(set) var peaksStartMs = 0

    /// 波形に表示している範囲
    private(set) var viewStartMs: Int
    private(set) var viewSpanMs: Int
    /// ドラッグとピンチを始めたときの表示範囲
    private var dragOrigin: (startMs: Int, spanMs: Int)?
    private var magnifyOrigin: (startMs: Int, spanMs: Int)?

    init(block: TimeRange) {
        self.block = block
        viewStartMs = block.startMs
        viewSpanMs = max(1, block.durationMs)
    }

    var viewRange: TimeRange { TimeRange(startMs: viewStartMs, endMs: viewStartMs + viewSpanMs) }

    /// ブロックの範囲の波形（20msごと）を読む
    func loadPeaks(recordingId: UUID) async {
        let step = PeakFile.msPerPeak50
        let first = block.startMs / step
        let count = block.durationMs / step + 2
        let peaks = await Task.detached {
            (try? PeakFile(url: FileLayout.peaks50(recordingId)))?.read(from: first, count: count) ?? []
        }.value
        self.peaks = peaks
        peaksStartMs = first * step
    }

    // MARK: - 取り消し

    func record(_ edit: EditorEdit?) {
        if let edit { history.record(edit) }
    }

    func undo(_ service: EditorService) {
        if let edit = history.undo() { service.apply(edit, undo: true) }
    }

    func redo(_ service: EditorService) {
        if let edit = history.redo() { service.apply(edit, undo: false) }
    }

    // MARK: - 再生位置

    /// 再生位置に合わせて、ハイライトするセグメントを決め、再生中なら波形の表示範囲を追いかける
    func follow(_ ms: Int, isPlaying: Bool, segments: [TimeRange], ids: [UUID]) {
        let id = indexOfRange(containing: ms, in: segments).map { ids[$0] }
        if id != currentSegmentId { currentSegmentId = id }
        if isPlaying, dragOrigin == nil, magnifyOrigin == nil, !viewRange.contains(ms), block.contains(ms) {
            setView(start: ms - viewSpanMs / 10, span: viewSpanMs)
        }
    }

    // MARK: - 波形の操作

    /// 波形の横位置（0〜1）を時刻にする
    func ms(atFraction fraction: CGFloat) -> Int {
        let ms = viewStartMs + Int(min(max(0, fraction), 1) * CGFloat(viewSpanMs))
        return min(max(ms, block.startMs), block.endMs)
    }

    /// ドラッグ。範囲選択中なら選択範囲を、そうでなければ表示範囲を動かす
    func drag(from start: CGFloat, to current: CGFloat, ended: Bool) {
        let origin = dragOrigin ?? (viewStartMs, viewSpanMs)
        dragOrigin = ended ? nil : origin
        if selectingRange {
            let a = originMs(atFraction: start, origin), b = originMs(atFraction: current, origin)
            let range = TimeRange(startMs: min(a, b), endMs: max(a, b))
            selection = range.durationMs > 0 ? .range(range) : nil
        } else {
            let delta = Int((start - current) * CGFloat(origin.spanMs))
            setView(start: origin.startMs + delta, span: origin.spanMs)
        }
    }

    /// ピンチで拡大・縮小する。表示の中央を保つ
    func magnify(by scale: CGFloat, ended: Bool) {
        let origin = magnifyOrigin ?? (viewStartMs, viewSpanMs)
        magnifyOrigin = ended ? nil : origin
        let span = Int(CGFloat(origin.spanMs) / max(scale, 0.01))
        let center = origin.startMs + origin.spanMs / 2
        let clampedSpan = min(max(span, min(Self.minSpanMs, block.durationMs)), block.durationMs)
        setView(start: center - clampedSpan / 2, span: clampedSpan)
    }

    /// 全体を表示する
    func showWholeBlock() {
        setView(start: block.startMs, span: block.durationMs)
    }

    var isZoomed: Bool { viewSpanMs < block.durationMs }

    private func originMs(atFraction fraction: CGFloat, _ origin: (startMs: Int, spanMs: Int)) -> Int {
        let ms = origin.startMs + Int(min(max(0, fraction), 1) * CGFloat(origin.spanMs))
        return min(max(ms, block.startMs), block.endMs)
    }

    private func setView(start: Int, span: Int) {
        let span = max(1, min(span, block.durationMs))
        viewSpanMs = span
        viewStartMs = min(max(start, block.startMs), block.endMs - span)
    }
}
