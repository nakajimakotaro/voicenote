import AudioIO
import Domain
import Foundation
import SwiftData

/// 書き出し。txtとカットを適用したmp3を一時フォルダ（tmp/work/export/）に作り、共有シートに渡すURLを返す。
/// 前回の書き出しは始める前に消す。時刻はtxtもmp3もカット後の時間で揃える
@MainActor
struct ExportService {
    enum Kind: String, CaseIterable, Identifiable {
        case txt
        case mp3
        case both

        var id: Self { self }
        var label: String {
            switch self {
            case .txt: "txt"
            case .mp3: "mp3"
            case .both: "両方"
            }
        }

        var includesTxt: Bool { self != .mp3 }
        var includesMp3: Bool { self != .txt }
    }

    struct Request {
        let recording: Recording
        /// 開始時刻の順
        let blocks: [Block]
        let kind: Kind
        /// 複数のブロックを1つのtxtにまとめる
        let combineTxt: Bool
        let mp3Kbps: Int
    }

    struct Output {
        /// 共有シートに渡す順（txt、mp3の順）
        let files: [URL]
        /// txtが1つだけならその中身（クリップボードにコピーする用）
        let singleTxt: String?
        /// すべてカットしていてmp3を作らなかったブロック
        let skippedMp3: [String]
    }

    static let mp3SampleRate = 44_100.0
    /// つなぎ目のプツッという音を防ぐフェード
    static let fadeMs = 30

    let context: ModelContext

    /// - Parameter onProgress: mp3を1つ作り終えるごとに（作り終えた数, 全体の数）で呼ぶ
    func export(_ request: Request, onProgress: (Int, Int) -> Void) async throws -> Output {
        let recording = request.recording
        let blocks = request.blocks.map(snapshot)
        let source = FileLayout.source(recording.id, fileName: recording.sourceFileName)
        try FileLayout.resetExportDir()

        var taken: Set<String> = []
        func url(name: String, ext: String) -> URL {
            let fileName = exportFileName(recordedAt: recording.createdAt, name: name, ext: ext, taken: taken)
            taken.insert(fileName)
            return FileLayout.exportDir.appendingPathComponent(fileName)
        }

        var files: [URL] = []
        var texts: [String] = []
        if request.kind.includesTxt {
            let groups = request.combineTxt && blocks.count > 1 ? [blocks] : blocks.map { [$0] }
            for group in groups {
                let txt = formatTxt(TxtInput(recordingName: recording.name, recordedAt: recording.createdAt,
                                             blocks: group))
                let file = url(name: group.count == 1 ? group[0].title : recording.name, ext: "txt")
                try Data(txt.utf8).write(to: file)
                files.append(file)
                texts.append(txt)
            }
        }

        var skipped: [String] = []
        if request.kind.includesMp3 {
            let targets = blocks.filter { !keepRanges(block: $0.range, cuts: $0.cuts).isEmpty }
            skipped = blocks.filter { b in !targets.contains { $0.range == b.range } }.map(\.title)
            onProgress(0, targets.count)
            for (i, block) in targets.enumerated() {
                let file = url(name: block.title, ext: "mp3")
                _ = try await renderMp3(input: source, ranges: keepRanges(block: block.range, cuts: block.cuts),
                                        output: file, sampleRate: Self.mp3SampleRate, kbps: request.mp3Kbps,
                                        fadeMs: Self.fadeMs)
                files.append(file)
                onProgress(i + 1, targets.count)
            }
        }
        return Output(files: files, singleTxt: texts.count == 1 ? texts[0] : nil, skippedMp3: skipped)
    }

    /// txtとmp3に使う値を取り出す。文字起こしは別のコンテキストで保存されるので、関連ではなく取得し直す
    private func snapshot(_ block: Block) -> TxtBlock {
        let id = block.id
        let segments = (try? context.fetch(FetchDescriptor<Segment>(
            predicate: #Predicate { segment in
                if let block = segment.block { return block.id == id } else { return false }
            },
            sortBy: [SortDescriptor(\.startMs)]
        ))) ?? []
        return TxtBlock(
            title: BlockService.displayTitle(block),
            range: block.range,
            cuts: EditorService.cutRanges(block),
            memo: block.memo,
            segments: segments.map { TxtSegment(range: $0.range, text: $0.state == .done ? $0.displayText : nil) }
        )
    }
}
