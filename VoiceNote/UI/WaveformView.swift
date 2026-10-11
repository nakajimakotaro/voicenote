import AudioIO
import Domain
import SwiftUI

/// エディタの波形。表示範囲の分だけを描き、カット（グレー）、選択範囲、セグメントの区切り、再生位置を重ねる。
/// タップ、ドラッグ、ピンチは横位置の割合（0〜1）で知らせ、時刻への変換は呼び出し側で行う
struct WaveformView: View {
    let peaks: [UInt8]
    /// `peaks` の先頭の時刻
    let peaksStartMs: Int
    let viewRange: TimeRange
    let cuts: [TimeRange]
    let selection: TimeRange?
    /// セグメントの境目
    let boundaries: [Int]
    let player: PlayerModel
    var onTap: (CGFloat) -> Void
    /// 始点、現在位置、指を離したらtrue
    var onDrag: (CGFloat, CGFloat, Bool) -> Void
    var onMagnify: (CGFloat, Bool) -> Void

    var body: some View {
        GeometryReader { geo in
            let width = max(1, geo.size.width)
            ZStack(alignment: .topLeading) {
                canvas
                Playhead(player: player, viewRange: viewRange)
            }
            .contentShape(Rectangle())
            .onTapGesture { onTap($0.x / width) }
            .gesture(
                DragGesture(minimumDistance: 8)
                    .onChanged { onDrag($0.startLocation.x / width, $0.location.x / width, false) }
                    .onEnded { onDrag($0.startLocation.x / width, $0.location.x / width, true) }
            )
            .simultaneousGesture(
                MagnifyGesture()
                    .onChanged { onMagnify($0.magnification, false) }
                    .onEnded { onMagnify($0.magnification, true) }
            )
        }
    }

    private var canvas: some View {
        let peaks = peaks, peaksStartMs = peaksStartMs, view = viewRange
        let cuts = cuts, selection = selection, boundaries = boundaries
        return Canvas { ctx, size in
            let w = size.width, h = size.height
            let span = CGFloat(max(1, view.durationMs))
            func x(_ ms: Int) -> CGFloat { CGFloat(ms - view.startMs) / span * w }
            func rect(_ r: TimeRange) -> CGRect {
                let x0 = max(0, x(r.startMs)), x1 = min(w, x(r.endMs))
                return CGRect(x: x0, y: 0, width: max(1, x1 - x0), height: h)
            }

            ctx.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 6),
                     with: .color(Color(.secondarySystemFill)))

            // 1ピクセルの列に入るピークの最大値を描く
            let step = CGFloat(PeakFile.msPerPeak50)
            let mid = h / 2
            var wave = Path()
            if !peaks.isEmpty {
                for col in 0 ..< Int(w.rounded(.up)) {
                    let msLo = CGFloat(view.startMs) + CGFloat(col) / w * span
                    let msHi = CGFloat(view.startMs) + CGFloat(col + 1) / w * span
                    let lo = max(0, Int((msLo - CGFloat(peaksStartMs)) / step))
                    let hi = min(peaks.count, max(lo + 1, Int((msHi - CGFloat(peaksStartMs)) / step)))
                    guard lo < hi else { continue }
                    let amp = CGFloat(peaks[lo ..< hi].max() ?? 0) / 255 * (h / 2 - 4)
                    wave.addRect(CGRect(x: CGFloat(col), y: mid - amp, width: 1, height: max(0.5, amp * 2)))
                }
            }
            ctx.fill(wave, with: .color(.primary.opacity(0.6)))

            var bounds = Path()
            for ms in boundaries where view.contains(ms) {
                bounds.addRect(CGRect(x: x(ms), y: 0, width: 1, height: h))
            }
            ctx.fill(bounds, with: .color(.secondary.opacity(0.5)))

            // カットは波形を薄くしてグレーをかぶせる
            for cut in cuts where cut.overlaps(view) {
                ctx.fill(Path(rect(cut)), with: .color(Color(.systemBackground).opacity(0.55)))
                ctx.fill(Path(rect(cut)), with: .color(.gray.opacity(0.35)))
            }

            if let selection, selection.overlaps(view) {
                let r = rect(selection)
                ctx.fill(Path(r), with: .color(.accentColor.opacity(0.22)))
                ctx.stroke(Path(r.insetBy(dx: 1, dy: 1)), with: .color(.accentColor), lineWidth: 2)
            }
        }
    }
}

/// 再生位置の線。位置だけを読むので、再生中に描き直されるのはこのビューだけ
private struct Playhead: View {
    let player: PlayerModel
    let viewRange: TimeRange

    var body: some View {
        GeometryReader { geo in
            let ms = player.positionMs
            if viewRange.contains(ms) {
                Rectangle()
                    .fill(.red)
                    .frame(width: 2)
                    .offset(x: CGFloat(ms - viewRange.startMs) / CGFloat(max(1, viewRange.durationMs)) * geo.size.width - 1)
                    .allowsHitTesting(false)
            }
        }
    }
}
