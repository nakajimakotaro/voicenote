import AudioIO
import Domain
import Foundation
import Observation

/// 画面に描くブロック。SwiftDataのBlockと、スライダー操作中の仮のブロックの両方をこの形にする
struct BlockItem: Identifiable, Hashable {
    let id: UUID
    /// 先頭からの通し番号（1から）
    let number: Int
    let range: TimeRange
    let status: BlockStatus
    let title: String
    let manuallyEdited: Bool
    /// 文字起こしの実行中で、範囲を変えられない
    let locked: Bool

    var displayTitle: String { title.isEmpty ? "ブロック \(number)" : title }
}

@MainActor
@Observable
final class BlocksViewModel {
    enum Mode: String, CaseIterable, Identifiable {
        case timeline
        case list

        var id: Self { self }
        var label: String { self == .timeline ? "タイムライン" : "リスト" }
    }

    /// 1行の長さの選択肢（分）
    static let rowMinutesOptions = [5, 10, 15, 30]

    var mode: Mode = .timeline
    private(set) var rowMs = 10 * 60_000
    var selectedId: UUID?

    private(set) var loaded = false
    private(set) var loadError: String?
    private(set) var regions: [TimeRange] = []
    private(set) var peaks: PeakFile?
    /// 発話区間を行ごとに分けたもの
    private(set) var regionRows: [Int: [RowPiece]] = [:]

    /// 分割パラメータ（秒）。スライダーと結びつける
    var gapSec: Double = 30
    var minSec: Double = 20
    /// スライダーを動かしている間だけtrue。このあいだは仮のブロックを表示し、離したら保存する
    private(set) var editingParams = false
    private(set) var preview: [BlockDraft]?

    var rowMinutes: Int { rowMs / 60_000 }
    var gapMs: Int { Int(gapSec) * 1000 }
    var minBlockMs: Int { Int(minSec) * 1000 }

    /// 発話区間とピークを読み込む。読み込めたら発話区間を返す
    func load(_ recording: Recording) async -> [TimeRange]? {
        if loaded { return regions }
        let id = recording.id
        do {
            let (regions, peaks) = try await Task.detached {
                let regions = try readRegions(from: FileLayout.regions(id))
                let peaks = try? PeakFile(url: FileLayout.peaks1(id))
                return (regions, peaks)
            }.value
            self.regions = regions
            self.peaks = peaks
            rebuildRegionRows()
            loaded = true
            return regions
        } catch {
            loadError = "解析結果を読み込めませんでした"
            return nil
        }
    }

    func setParams(gapMs: Int, minBlockMs: Int) {
        gapSec = Double(gapMs / 1000)
        minSec = Double(minBlockMs / 1000)
    }

    func setRowMinutes(_ minutes: Int) {
        guard minutes * 60_000 != rowMs else { return }
        rowMs = minutes * 60_000
        rebuildRegionRows()
    }

    /// ピンチで1行の長さを変える。広げると短く（拡大）、つまむと長くする
    func zoom(by magnification: CGFloat) {
        let options = Self.rowMinutesOptions
        guard let index = options.firstIndex(of: rowMinutes) else { return }
        if magnification > 1.3, index > 0 {
            setRowMinutes(options[index - 1])
        } else if magnification < 0.77, index + 1 < options.count {
            setRowMinutes(options[index + 1])
        }
    }

    func beginEditingParams() {
        editingParams = true
    }

    /// スライダーの値が変わったら、保存せずに仮のブロックを作り直す
    func updatePreview(_ recording: Recording) {
        guard editingParams else { return }
        preview = buildBlocks(regions: regions, gapMs: gapMs, minBlockMs: minBlockMs,
                              manual: BlockService.fixedDrafts(recording))
    }

    /// スライダーを離したら保存する
    func commitParams(_ recording: Recording, service: BlockService) {
        editingParams = false
        preview = nil
        service.regenerate(recording, regions: regions, gapMs: gapMs, minBlockMs: minBlockMs)
        dropMissingSelection(recording)
    }

    /// 手で調整したブロックも含めて作り直す
    func resetManual(_ recording: Recording, service: BlockService) {
        service.regenerate(recording, regions: regions, gapMs: gapMs, minBlockMs: minBlockMs, keepManual: false)
        dropMissingSelection(recording)
    }

    /// 表示するブロック。スライダー操作中は仮のブロック。`transcribing` ならすべて範囲を変えられない
    func items(_ recording: Recording, transcribing: Bool) -> [BlockItem] {
        if let preview {
            return preview.enumerated().map { i, draft in
                BlockItem(id: UUID(), number: i + 1, range: draft.range, status: draft.status, title: "",
                          manuallyEdited: draft.manuallyEdited, locked: false)
            }
        }
        return BlockService.sorted(recording).enumerated().map { i, block in
            BlockItem(id: block.id, number: i + 1, range: block.range, status: block.status, title: block.title,
                      manuallyEdited: block.manuallyEdited, locked: transcribing)
        }
    }

    private func dropMissingSelection(_ recording: Recording) {
        if let id = selectedId, !recording.blocks.contains(where: { $0.id == id }) {
            selectedId = nil
        }
    }

    private func rebuildRegionRows() {
        regionRows = Dictionary(grouping: splitIntoRows(regions, rowMs: rowMs), by: \.row)
    }
}
