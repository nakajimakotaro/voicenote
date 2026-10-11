import Domain
import SwiftUI

/// 1行に描くブロックの一部
struct BlockPiece: Hashable {
    let piece: RowPiece
    let item: BlockItem
}

extension BlockStatus {
    var label: String {
        switch self {
        case .candidate: "候補"
        case .selected: "採用"
        case .excluded: "除外"
        }
    }

    var color: Color {
        switch self {
        case .candidate: .blue
        case .selected: .green
        case .excluded: .gray
        }
    }
}

/// 折り返しタイムラインの1行。波形、発話区間、ブロックの帯を重ねて描く。
/// タップでその位置を知らせ、選択中のブロックの端はドラッグで動かせる
struct RowTimelineView: View {
    static let height: CGFloat = 52

    let row: Int
    let rowMs: Int
    let totalMs: Int
    /// この行のピーク（1秒1点）
    let peaks: [UInt8]
    let regions: [RowPiece]
    let blocks: [BlockPiece]
    let selectedId: UUID?
    let player: PlayerModel
    var onTap: (Int) -> Void
    /// 端のドラッグ。最後の引数は指を離したときtrue
    var onDragEdge: ((UUID, BlockEdge, Int, Bool) -> Void)?

    private var rowStartMs: Int { row * rowMs }

    var body: some View {
        HStack(spacing: 6) {
            Text(Format.duration(ms: rowStartMs))
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 46, alignment: .trailing)
            GeometryReader { geo in
                ZStack(alignment: .topLeading) {
                    canvas
                        .contentShape(Rectangle())
                        .onTapGesture { location in onTap(ms(atX: location.x, width: geo.size.width)) }
                    RowPlayhead(player: player, rowStartMs: rowStartMs, rowMs: rowMs)
                    handles(width: geo.size.width)
                }
                .coordinateSpace(.named(spaceName))
            }
            .frame(height: Self.height)
        }
    }

    private var spaceName: String { "row-\(row)" }

    private func ms(atX x: CGFloat, width: CGFloat) -> Int {
        let ratio = min(max(0, x / max(1, width)), 1)
        return min(totalMs, rowStartMs + Int(ratio * CGFloat(rowMs)))
    }

    private var canvas: some View {
        let rowStartMs = rowStartMs, rowMs = rowMs, totalMs = totalMs
        let peaks = peaks, regions = regions, blocks = blocks, selectedId = selectedId
        return Canvas { ctx, size in
            let w = size.width, h = size.height
            func x(_ ms: Int) -> CGFloat { CGFloat(ms - rowStartMs) / CGFloat(rowMs) * w }
            let usedWidth = min(w, x(totalMs))
            ctx.fill(Path(roundedRect: CGRect(x: 0, y: 0, width: usedWidth, height: h), cornerRadius: 4),
                     with: .color(Color(.secondarySystemFill)))

            for bp in blocks {
                let rect = CGRect(x: x(bp.piece.startMs), y: 0, width: max(1, x(bp.piece.endMs) - x(bp.piece.startMs)), height: h)
                if bp.item.status == .excluded {
                    // 背景と同じ灰色系なので、斜線で除外とわかるようにする
                    ctx.fill(Path(rect), with: .color(.gray.opacity(0.18)))
                    var hatch = Path()
                    var hx = rect.minX - h
                    while hx < rect.maxX {
                        hatch.move(to: CGPoint(x: hx, y: h))
                        hatch.addLine(to: CGPoint(x: hx + h, y: 0))
                        hx += 6
                    }
                    ctx.drawLayer { layer in
                        layer.clip(to: Path(rect))
                        layer.stroke(hatch, with: .color(.gray.opacity(0.45)), lineWidth: 1)
                    }
                } else {
                    ctx.fill(Path(rect), with: .color(bp.item.status.color.opacity(0.28)))
                }
            }

            // 波形。1ピクセルの列に入るピークの最大値を描く
            let waveHeight = h - 8
            let mid = waveHeight / 2 + 1
            let perRow = Double(rowMs) / 1000
            var wave = Path()
            if !peaks.isEmpty {
                for col in 0 ..< Int(usedWidth.rounded(.up)) {
                    let lo = Int(Double(col) / Double(w) * perRow)
                    let hi = min(peaks.count, max(lo + 1, Int(Double(col + 1) / Double(w) * perRow)))
                    guard lo < hi else { break }
                    let peak = peaks[lo ..< hi].max() ?? 0
                    let amp = CGFloat(peak) / 255 * waveHeight / 2
                    wave.addRect(CGRect(x: CGFloat(col), y: mid - amp, width: 1, height: max(0.5, amp * 2)))
                }
            }
            ctx.fill(wave, with: .color(.primary.opacity(0.55)))

            // 発話区間は下端の細い帯
            var speech = Path()
            for p in regions {
                speech.addRect(CGRect(x: x(p.startMs), y: h - 4, width: max(1, x(p.endMs) - x(p.startMs)), height: 3))
            }
            ctx.fill(speech, with: .color(.orange))

            for bp in blocks where bp.item.id == selectedId {
                let rect = CGRect(x: x(bp.piece.startMs), y: 1, width: max(1, x(bp.piece.endMs) - x(bp.piece.startMs)), height: h - 2)
                ctx.stroke(Path(rect), with: .color(.accentColor), lineWidth: 2)
            }
        }
    }

    /// 選択中のブロックの端。行の中でだけ動かせる
    @ViewBuilder
    private func handles(width: CGFloat) -> some View {
        if let onDragEdge {
            // 範囲はドラッグ中に変わるので、IDにはブロックのidを使う（変わるとジェスチャーが途切れる）
            ForEach(blocks.filter { $0.item.id == selectedId && !$0.item.locked }, id: \.item.id) { bp in
                if bp.piece.containsStart {
                    handle(bp.item.id, .start, at: bp.piece.startMs, width: width, onDrag: onDragEdge)
                }
                if bp.piece.containsEnd {
                    handle(bp.item.id, .end, at: bp.piece.endMs, width: width, onDrag: onDragEdge)
                }
            }
        }
    }

    private func handle(_ id: UUID, _ edge: BlockEdge, at ms: Int, width: CGFloat,
                        onDrag: @escaping (UUID, BlockEdge, Int, Bool) -> Void) -> some View {
        let x = CGFloat(ms - rowStartMs) / CGFloat(rowMs) * width
        return Capsule()
            .fill(Color.accentColor)
            .frame(width: 6, height: Self.height - 8)
            .frame(width: 30, height: Self.height)
            .contentShape(Rectangle())
            .position(x: x, y: Self.height / 2)
            .highPriorityGesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named(spaceName))
                    .onChanged { onDrag(id, edge, self.ms(atX: $0.location.x, width: width), false) }
                    .onEnded { onDrag(id, edge, self.ms(atX: $0.location.x, width: width), true) }
            )
            .accessibilityLabel(edge == .start ? "ブロックの開始" : "ブロックの終了")
    }
}

/// 再生位置の線。位置だけを読むので、再生中に描き直されるのはこのビューだけ
private struct RowPlayhead: View {
    let player: PlayerModel
    let rowStartMs: Int
    let rowMs: Int

    var body: some View {
        GeometryReader { geo in
            let ms = player.positionMs
            if (player.isPlaying || ms > 0), ms >= rowStartMs, ms < rowStartMs + rowMs {
                Rectangle()
                    .fill(.red)
                    .frame(width: 2)
                    .offset(x: CGFloat(ms - rowStartMs) / CGFloat(rowMs) * geo.size.width - 1)
                    .allowsHitTesting(false)
            }
        }
    }
}
