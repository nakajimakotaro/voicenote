import AudioIO
import Domain
import SwiftUI

/// エディタの波形。表示範囲の分だけを描き、カット（グレー）、選択範囲（黄色いトリム枠）、
/// セグメントの区切り、再生位置を重ねる。
/// 選択範囲の左右の黄色いハンドルをドラッグして開始・終了を個別に固定でき、
/// それ以外の部分のドラッグ・ピンチで表示範囲の移動と拡大縮小を行う
struct WaveformView: View {
    static let handleWidth: CGFloat = 20
    static let borderWidth: CGFloat = 4
    static let cornerRadius: CGFloat = 8
    static let trimYellow = Color(red: 0.98, green: 0.79, blue: 0.14)

    @Environment(\.colorScheme) private var colorScheme

    let peaks: [UInt8]
    /// `peaks` の先頭の時刻
    let peaksStartMs: Int
    let blockRange: TimeRange
    let viewRange: TimeRange
    let cuts: [TimeRange]
    let selection: TimeRange?
    /// セグメントの境目
    let boundaries: [Int]
    let player: PlayerModel
    var onTap: (CGFloat) -> Void
    /// 表示範囲のスクロール（始点、現在位置、指を離したらtrue）
    var onPan: (CGFloat, CGFloat, Bool) -> Void
    /// 選択範囲の左右ハンドルのドラッグ（端、移動量の割合、指を離したらtrue）
    var onDragEdge: (EditorModel.SelectionEdge, CGFloat, Bool) -> Void
    var onCancelEdgeDrag: () -> Void
    var onMagnify: (CGFloat, Bool) -> Void

    @State private var draggingEdge: EditorModel.SelectionEdge?
    @State private var hapticCount = 0

    private let spaceName = "waveform"

    var body: some View {
        GeometryReader { geo in
            let totalWidth = max(1, geo.size.width)
            let trackMinX = Self.handleWidth
            let trackWidth = max(1, totalWidth - Self.handleWidth * 2)
            ZStack(alignment: .topLeading) {
                canvas
                    .contentShape(Rectangle())
                    .onTapGesture { location in
                        onTap((location.x - trackMinX) / trackWidth)
                    }
                    .gesture(
                        DragGesture(minimumDistance: 8, coordinateSpace: .named(spaceName))
                            .onChanged {
                                onPan(
                                    ($0.startLocation.x - trackMinX) / trackWidth,
                                    ($0.location.x - trackMinX) / trackWidth,
                                    false
                                )
                            }
                            .onEnded {
                                onPan(
                                    ($0.startLocation.x - trackMinX) / trackWidth,
                                    ($0.location.x - trackMinX) / trackWidth,
                                    true
                                )
                            }
                    )
                    .simultaneousGesture(
                        MagnifyGesture()
                            .onChanged { onMagnify($0.magnification, false) }
                            .onEnded { onMagnify($0.magnification, true) }
                    )

                if selection != nil {
                    trimFrame
                        .allowsHitTesting(false)
                }

                Playhead(
                    player: player,
                    viewRange: viewRange,
                    selection: selection,
                    trackMinX: trackMinX,
                    trackWidth: trackWidth,
                    height: geo.size.height
                )

                if let selection {
                    trimHandles(selection: selection, size: geo.size, trackMinX: trackMinX, trackWidth: trackWidth)
                }
            }
            .coordinateSpace(.named(spaceName))
            .sensoryFeedback(.selection, trigger: hapticCount)
        }
    }

    // MARK: - 波形・カット・暗転マスク

    private var canvas: some View {
        let peaks = peaks, peaksStartMs = peaksStartMs
        let block = blockRange, view = viewRange
        let cuts = cuts, selection = selection, boundaries = boundaries
        let dimOpacity = colorScheme == .dark ? 0.52 : 0.30
        return Canvas { ctx, size in
            let w = size.width, h = size.height
            let trackMinX = Self.handleWidth
            let trackWidth = max(1, w - Self.handleWidth * 2)
            let span = CGFloat(max(1, view.durationMs))
            func x(_ ms: Int) -> CGFloat { trackMinX + CGFloat(ms - view.startMs) / span * trackWidth }
            func ms(atX px: CGFloat) -> CGFloat { CGFloat(view.startMs) + (px - trackMinX) / trackWidth * span }

            let clipPath = Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: Self.cornerRadius)
            ctx.fill(clipPath, with: .color(Color(.secondarySystemFill)))

            ctx.drawLayer { layer in
                layer.clip(to: clipPath)

                // 1ピクセルの列に入るピークの最大値を描く
                let step = CGFloat(PeakFile.msPerPeak50)
                let mid = h / 2
                let maxAmp = max(1, h / 2 - Self.borderWidth - 3)
                var wave = Path()
                if !peaks.isEmpty {
                    let blockMinX = max(0, Int(x(block.startMs).rounded(.down)))
                    let blockMaxX = min(Int(w.rounded(.up)), Int(x(block.endMs).rounded(.up)))
                    if blockMinX < blockMaxX {
                        for col in blockMinX ..< blockMaxX {
                            let msLo = max(CGFloat(block.startMs), ms(atX: CGFloat(col)))
                            let msHi = min(CGFloat(block.endMs), ms(atX: CGFloat(col + 1)))
                            guard msLo < msHi else { continue }
                            let lo = max(0, Int((msLo - CGFloat(peaksStartMs)) / step))
                            let hi = min(peaks.count, max(lo + 1, Int((msHi - CGFloat(peaksStartMs)) / step)))
                            guard lo < hi else { continue }
                            let amp = CGFloat(peaks[lo ..< hi].max() ?? 0) / 255 * maxAmp
                            wave.addRect(CGRect(x: CGFloat(col), y: mid - amp, width: 1, height: max(0.5, amp * 2)))
                        }
                    }
                }
                layer.fill(wave, with: .color(.primary.opacity(0.6)))

                let canvasRange = TimeRange(startMs: Int(ms(atX: 0).rounded(.down)),
                                            endMs: Int(ms(atX: w).rounded(.up)))

                var bounds = Path()
                for bMs in boundaries where canvasRange.contains(bMs) {
                    bounds.addRect(CGRect(x: x(bMs), y: 0, width: 1, height: h))
                }
                layer.fill(bounds, with: .color(.secondary.opacity(0.5)))

                // カットは波形を薄くしてグレーをかぶせる
                for cut in cuts where cut.overlaps(canvasRange) {
                    let x0 = max(0, x(cut.startMs)), x1 = min(w, x(cut.endMs))
                    let r = CGRect(x: x0, y: 0, width: max(1, x1 - x0), height: h)
                    layer.fill(Path(r), with: .color(Color(.systemBackground).opacity(0.55)))
                    layer.fill(Path(r), with: .color(.gray.opacity(0.35)))
                }

                // 選択範囲の外側を暗くして、選んだ区間を際立たせる
                if let selection {
                    let clearLeft = min(max(0, x(selection.startMs)), w)
                    let clearRight = min(max(0, x(selection.endMs)), w)
                    if clearLeft > 0 {
                        layer.fill(Path(CGRect(x: 0, y: 0, width: clearLeft, height: h)),
                                   with: .color(.black.opacity(dimOpacity)))
                    }
                    if clearRight < w {
                        layer.fill(Path(CGRect(x: clearRight, y: 0, width: w - clearRight, height: h)),
                                   with: .color(.black.opacity(dimOpacity)))
                    }
                }
            }
        }
    }

    // MARK: - 黄色いトリム枠

    private var trimFrame: some View {
        let view = viewRange, selection = selection, draggingEdge = draggingEdge
        return Canvas { ctx, size in
            guard let selection else { return }
            guard selection.endMs >= view.startMs && selection.startMs <= view.endMs else { return }

            let w = size.width, h = size.height
            let handleW = Self.handleWidth
            let borderW = Self.borderWidth
            let radius = Self.cornerRadius
            let trackMinX = handleW
            let trackWidth = max(1, w - handleW * 2)
            let span = CGFloat(max(1, view.durationMs))
            func x(_ ms: Int) -> CGFloat { trackMinX + CGFloat(ms - view.startMs) / span * trackWidth }

            let startX = x(selection.startMs)
            let endX = x(selection.endMs)
            let leftVisible = selection.startMs >= view.startMs && selection.startMs <= view.endMs
            let rightVisible = selection.endMs >= view.startMs && selection.endMs <= view.endMs

            let outerLeft = leftVisible ? startX - handleW : 0
            let outerRight = rightVisible ? endX + handleW : w
            let outerRect = CGRect(x: outerLeft, y: 0, width: max(0, outerRight - outerLeft), height: h)

            var framePath = UnevenRoundedRectangle(
                topLeadingRadius: leftVisible ? radius : 0,
                bottomLeadingRadius: leftVisible ? radius : 0,
                bottomTrailingRadius: rightVisible ? radius : 0,
                topTrailingRadius: rightVisible ? radius : 0
            ).path(in: outerRect)

            let innerLeft = leftVisible ? startX : outerLeft
            let innerRight = rightVisible ? endX : outerRight
            if innerRight > innerLeft {
                let innerRect = CGRect(x: innerLeft, y: borderW,
                                       width: innerRight - innerLeft,
                                       height: max(0, h - borderW * 2))
                let innerPath = UnevenRoundedRectangle(
                    topLeadingRadius: leftVisible ? 1.5 : 0,
                    bottomLeadingRadius: leftVisible ? 1.5 : 0,
                    bottomTrailingRadius: rightVisible ? 1.5 : 0,
                    topTrailingRadius: rightVisible ? 1.5 : 0
                ).path(in: innerRect)
                framePath.addPath(innerPath)
            }

            ctx.fill(framePath, with: .color(Self.trimYellow), style: FillStyle(eoFill: true))

            // ドラッグ中のハンドルを少し明るくする
            if draggingEdge == .start, leftVisible {
                let r = CGRect(x: startX - handleW, y: 0, width: handleW, height: h)
                let p = UnevenRoundedRectangle(topLeadingRadius: radius, bottomLeadingRadius: radius,
                                               bottomTrailingRadius: 0, topTrailingRadius: 0).path(in: r)
                ctx.fill(p, with: .color(.white.opacity(0.24)))
            }
            if draggingEdge == .end, rightVisible {
                let r = CGRect(x: endX, y: 0, width: handleW, height: h)
                let p = UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 0,
                                               bottomTrailingRadius: radius, topTrailingRadius: radius).path(in: r)
                ctx.fill(p, with: .color(.white.opacity(0.24)))
            }

            // 左右ハンドルのシェブロン（< と >）
            let chevronStyle = StrokeStyle(lineWidth: 2.8, lineCap: .round, lineJoin: .round)
            let chevronColor = Color.black.opacity(0.85)
            let cy = h / 2
            let chevronHalfH: CGFloat = min(12, h * 0.14)
            if leftVisible {
                let cx = startX - handleW / 2
                var chevron = Path()
                chevron.move(to: CGPoint(x: cx + 2.5, y: cy - chevronHalfH))
                chevron.addLine(to: CGPoint(x: cx - 3.0, y: cy))
                chevron.addLine(to: CGPoint(x: cx + 2.5, y: cy + chevronHalfH))
                ctx.stroke(chevron, with: .color(chevronColor), style: chevronStyle)
            }
            if rightVisible {
                let cx = endX + handleW / 2
                var chevron = Path()
                chevron.move(to: CGPoint(x: cx - 2.5, y: cy - chevronHalfH))
                chevron.addLine(to: CGPoint(x: cx + 3.0, y: cy))
                chevron.addLine(to: CGPoint(x: cx - 2.5, y: cy + chevronHalfH))
                ctx.stroke(chevron, with: .color(chevronColor), style: chevronStyle)
            }
        }
        .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
    }

    // MARK: - 左右ハンドルのタッチ領域

    @ViewBuilder
    private func trimHandles(selection: TimeRange, size: CGSize, trackMinX: CGFloat, trackWidth: CGFloat) -> some View {
        let span = CGFloat(max(1, viewRange.durationMs))
        let startX = trackMinX + CGFloat(selection.startMs - viewRange.startMs) / span * trackWidth
        let endX = trackMinX + CGFloat(selection.endMs - viewRange.startMs) / span * trackWidth
        let leftVisible = selection.startMs >= viewRange.startMs && selection.startMs <= viewRange.endMs
        let rightVisible = selection.endMs >= viewRange.startMs && selection.endMs <= viewRange.endMs

        // 内側の拡張は選択幅の半分までに抑え、狭い選択範囲でも左右ハンドルが競合しないようにする
        let innerExtend = min(14, max(0, (endX - startX) / 2))
        let outerExtend: CGFloat = 16
        let hitHeight = size.height + 8

        let leftHit = CGRect(
            x: startX - Self.handleWidth - outerExtend,
            y: -4,
            width: Self.handleWidth + outerExtend + innerExtend,
            height: hitHeight
        )
        let rightHit = CGRect(
            x: endX - innerExtend,
            y: -4,
            width: Self.handleWidth + outerExtend + innerExtend,
            height: hitHeight
        )

        TrimHandleHitArea(
            edge: .start,
            isVisible: leftVisible,
            hitRect: leftHit,
            trackWidth: trackWidth,
            spaceName: spaceName,
            onDraggingChange: { active in updateDragging(.start, active: active) },
            onDrag: { delta, ended in onDragEdge(.start, delta, ended) },
            onCancel: onCancelEdgeDrag
        )
        TrimHandleHitArea(
            edge: .end,
            isVisible: rightVisible,
            hitRect: rightHit,
            trackWidth: trackWidth,
            spaceName: spaceName,
            onDraggingChange: { active in updateDragging(.end, active: active) },
            onDrag: { delta, ended in onDragEdge(.end, delta, ended) },
            onCancel: onCancelEdgeDrag
        )
    }

    private func updateDragging(_ edge: EditorModel.SelectionEdge, active: Bool) {
        if active {
            if draggingEdge != edge { hapticCount += 1 }
            draggingEdge = edge
        } else if draggingEdge == edge {
            draggingEdge = nil
        }
    }
}

/// トリム枠の片側のハンドル用の透明なドラッグ領域。
/// 表示位置が変わっても親の座標系で相対移動を計算するので、掴んだ瞬間にジャンプしない
private struct TrimHandleHitArea: View {
    let edge: EditorModel.SelectionEdge
    let isVisible: Bool
    let hitRect: CGRect
    let trackWidth: CGFloat
    let spaceName: String
    let onDraggingChange: (Bool) -> Void
    let onDrag: (CGFloat, Bool) -> Void
    let onCancel: () -> Void

    @GestureState private var dragging = false

    var body: some View {
        Color.clear
            .frame(width: max(1, hitRect.width), height: max(1, hitRect.height))
            .contentShape(Rectangle())
            .position(x: hitRect.midX, y: hitRect.midY)
            .allowsHitTesting(isVisible || dragging)
            .highPriorityGesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named(spaceName))
                    .updating($dragging) { _, state, _ in state = true }
                    .onChanged { value in
                        let delta = (value.location.x - value.startLocation.x) / max(1, trackWidth)
                        onDrag(delta, false)
                    }
                    .onEnded { value in
                        let delta = (value.location.x - value.startLocation.x) / max(1, trackWidth)
                        onDrag(delta, true)
                    }
            )
            .onChange(of: dragging) { was, now in
                onDraggingChange(now)
                if was, !now { onCancel() }
            }
            .accessibilityLabel(edge == .start ? "選択範囲の開始" : "選択範囲の終了")
    }
}

/// 再生位置の線。位置だけを読むので、再生中に描き直されるのはこのビューだけ
private struct Playhead: View {
    let player: PlayerModel
    let viewRange: TimeRange
    let selection: TimeRange?
    let trackMinX: CGFloat
    let trackWidth: CGFloat
    let height: CGFloat

    var body: some View {
        let ms = player.positionMs
        if ms >= viewRange.startMs, ms <= viewRange.endMs {
            let x = trackMinX + CGFloat(ms - viewRange.startMs) / CGFloat(max(1, viewRange.durationMs)) * trackWidth
            let inSelection = selection.map { ms >= $0.startMs && ms <= $0.endMs } == true
            let insetY: CGFloat = inSelection ? WaveformView.borderWidth + 1 : 0
            Capsule()
                .fill(.red)
                .shadow(color: .black.opacity(0.25), radius: 1, y: 0)
                .frame(width: 3, height: max(0, height - insetY * 2))
                .offset(x: x - 1.5, y: insetY)
                .allowsHitTesting(false)
        }
    }
}
