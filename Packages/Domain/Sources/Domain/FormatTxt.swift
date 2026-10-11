import Foundation

/// 書き出すtxtの材料。複数のブロックを渡すと1つのtxtにまとめる
public struct TxtInput: Sendable {
    public var recordingName: String
    public var recordedAt: Date
    public var blocks: [TxtBlock]
    /// 録音日を出すときのタイムゾーン
    public var timeZone: TimeZone

    public init(recordingName: String, recordedAt: Date, blocks: [TxtBlock], timeZone: TimeZone = .current) {
        self.recordingName = recordingName
        self.recordedAt = recordedAt
        self.blocks = blocks
        self.timeZone = timeZone
    }
}

public struct TxtBlock: Sendable {
    public var title: String
    public var range: TimeRange
    /// 正規化していなくてよい
    public var cuts: [TimeRange]
    public var memo: String
    /// 時刻の順に並んでいること
    public var segments: [TxtSegment]

    public init(title: String, range: TimeRange, cuts: [TimeRange], memo: String, segments: [TxtSegment]) {
        self.title = title
        self.range = range
        self.cuts = cuts
        self.memo = memo
        self.segments = segments
    }
}

public struct TxtSegment: Sendable {
    public var range: TimeRange
    /// 修正済みならそのテキスト。文字起こしが終わっていなければnil
    public var text: String?

    public init(range: TimeRange, text: String?) {
        self.range = range
        self.text = text
    }
}

/// LINEにそのまま貼っても読める素のテキストにする。
///
///     録音：渋谷
///     録音日：2026/10/11
///
///     ■ ブロック 1
///     長さ：12:34
///     メモ：…
///
///     [00:00] テキスト
///
/// 時刻はブロックの先頭からの、カット後の時間（書き出したmp3と揃う）。
/// カット後の長さが1時間を超えるブロックは `[h:mm:ss]` にする。
/// すべてカットされた行、文字起こしが終わっていない行、空の行は出さない。行の中の改行は空白にする
public func formatTxt(_ input: TxtInput) -> String {
    var lines = ["録音：\(input.recordingName)", "録音日：\(formatDate(input.recordedAt, timeZone: input.timeZone))"]
    for block in input.blocks {
        let cuts = normalizeCuts(block: block.range, cuts: block.cuts)
        let lengthMs = editedDurationMs(block: block.range, cuts: cuts)
        lines += ["", "■ \(block.title)", "長さ：\(formatDuration(ms: lengthMs))"]
        let memo = block.memo.trimmingCharacters(in: .whitespacesAndNewlines)
        if !memo.isEmpty { lines.append("メモ：\(memo)") }

        var body: [String] = []
        for segment in block.segments {
            let text = (segment.text ?? "")
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            guard !text.isEmpty else { continue }
            let startMs: Int
            switch visibility(of: segment.range, cuts: cuts) {
            case .full: startMs = segment.range.startMs
            case .partial(let kept): startMs = kept
            case .hidden: continue
            }
            let t = toEditedMs(startMs, cuts: cuts) - block.range.startMs
            body.append("[\(formatTimestamp(ms: t, withHours: lengthMs > 3_600_000))] \(text)")
        }
        if !body.isEmpty { lines += [""] + body }
    }
    return lines.joined(separator: "\n") + "\n"
}

/// カットを除いた長さ
public func editedDurationMs(block: TimeRange, cuts: [TimeRange]) -> Int {
    keepRanges(block: block, cuts: cuts).map(\.durationMs).reduce(0, +)
}

/// txtの行頭の時刻。65000 → "01:05"、`withHours` なら "0:01:05"
public func formatTimestamp(ms: Int, withHours: Bool) -> String {
    let total = max(0, ms) / 1000
    let h = total / 3600, m = total / 60 % 60, s = total % 60
    return withHours ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", total / 60, s)
}

/// 長さ。65000 → "1:05"、3725000 → "1:02:05"
func formatDuration(ms: Int) -> String {
    let total = max(0, ms) / 1000
    let h = total / 3600, m = total / 60 % 60, s = total % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
}

/// 2026/10/11
func formatDate(_ date: Date, timeZone: TimeZone) -> String {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    let c = calendar.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d/%02d/%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
}

/// 書き出すファイルの名前。`YYYYMMDD_名前.拡張子`。
/// ファイル名に使えない文字は `_` にし、長すぎる名前は切り詰める。`taken` と重なれば `_2` などを付ける
public func exportFileName(recordedAt: Date, name: String, ext: String, taken: Set<String> = [],
                           timeZone: TimeZone = .current) -> String {
    let date = formatDate(recordedAt, timeZone: timeZone).replacingOccurrences(of: "/", with: "")
    let invalid = CharacterSet(charactersIn: "/\\:?*\"<>|").union(.newlines).union(.controlCharacters)
    var safe = String(String.UnicodeScalarView(name.unicodeScalars.map { invalid.contains($0) ? "_" : $0 }))
        .trimmingCharacters(in: .whitespaces)
    // 先頭のドットは隠しファイルになるので外す
    while safe.hasPrefix(".") { safe.removeFirst() }
    safe = String(safe.prefix(60))
    let base = safe.isEmpty ? date : "\(date)_\(safe)"
    var candidate = "\(base).\(ext)"
    var n = 2
    while taken.contains(candidate) {
        candidate = "\(base)_\(n).\(ext)"
        n += 1
    }
    return candidate
}
