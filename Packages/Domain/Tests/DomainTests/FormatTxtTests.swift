import Foundation
import Testing
@testable import Domain

private func sec(_ s: Double, _ e: Double) -> TimeRange { TimeRange(startMs: Int(s * 1000), endMs: Int(e * 1000)) }

private let tokyo = TimeZone(identifier: "Asia/Tokyo")!
/// 2026/10/11 01:30（日本時間）
private let recordedAt = Date(timeIntervalSince1970: 1_791_649_800)

private func input(_ blocks: [TxtBlock]) -> TxtInput {
    TxtInput(recordingName: "渋谷", recordedAt: recordedAt, blocks: blocks, timeZone: tokyo)
}

struct FormatTxtTests {
    @Test func singleBlockWithHeaderAndLines() {
        let block = TxtBlock(title: "ブロック 1", range: sec(100, 200), cuts: [], memo: "  良かった  ",
                             segments: [TxtSegment(range: sec(100, 130), text: "こんにちは"),
                                        TxtSegment(range: sec(130, 200), text: "どこ行くの")])
        #expect(formatTxt(input([block])) == """
        録音：渋谷
        録音日：2026/10/11

        ■ ブロック 1
        長さ：1:40
        メモ：良かった

        [00:00] こんにちは
        [00:30] どこ行くの

        """)
    }

    @Test func timesAreAfterCuts() {
        let block = TxtBlock(title: "A", range: sec(100, 200), cuts: [sec(110, 120), sec(150, 170)], memo: "",
                             segments: [TxtSegment(range: sec(100, 130), text: "一"),
                                        TxtSegment(range: sec(130, 150), text: "二"),
                                        TxtSegment(range: sec(150, 170), text: "カットされた"),
                                        TxtSegment(range: sec(165, 200), text: "一部カット")])
        let txt = formatTxt(input([block]))
        #expect(txt.contains("長さ：1:10"))
        #expect(txt.contains("[00:00] 一\n[00:20] 二\n[00:40] 一部カット\n"))
        #expect(!txt.contains("カットされた"))
    }

    @Test func skipsUntranscribedAndEmptyAndJoinsNewlines() {
        let block = TxtBlock(title: "A", range: sec(0, 60), cuts: [], memo: "",
                             segments: [TxtSegment(range: sec(0, 10), text: nil),
                                        TxtSegment(range: sec(10, 20), text: "  \n "),
                                        TxtSegment(range: sec(20, 30), text: "一行目\n二行目\r\n三行目")])
        let txt = formatTxt(input([block]))
        #expect(txt.hasSuffix("長さ：1:00\n\n[00:20] 一行目 二行目 三行目\n"))
    }

    @Test func noLinesOmitsBody() {
        let block = TxtBlock(title: "A", range: sec(0, 60), cuts: [], memo: "", segments: [])
        #expect(formatTxt(input([block])).hasSuffix("■ A\n長さ：1:00\n"))
    }

    @Test func multipleBlocksInOneFile() {
        let a = TxtBlock(title: "A", range: sec(0, 60), cuts: [], memo: "", segments: [TxtSegment(range: sec(0, 60), text: "あ")])
        let b = TxtBlock(title: "B", range: sec(600, 700), cuts: [], memo: "メモ", segments: [TxtSegment(range: sec(650, 700), text: "い")])
        #expect(formatTxt(input([a, b])) == """
        録音：渋谷
        録音日：2026/10/11

        ■ A
        長さ：1:00

        [00:00] あ

        ■ B
        長さ：1:40
        メモ：メモ

        [00:50] い

        """)
    }

    @Test func hoursWhenBlockIsLongerThanAnHour() {
        let block = TxtBlock(title: "A", range: sec(0, 4000), cuts: [], memo: "",
                             segments: [TxtSegment(range: sec(0, 10), text: "最初"),
                                        TxtSegment(range: sec(3725, 3730), text: "後")])
        let txt = formatTxt(input([block]))
        #expect(txt.contains("長さ：1:06:40"))
        #expect(txt.contains("[0:00:00] 最初\n[1:02:05] 後\n"))
    }

    @Test func hoursOnlyAfterCuts() {
        // 元は1時間を超えるが、カット後は1時間以内
        let block = TxtBlock(title: "A", range: sec(0, 4000), cuts: [sec(0, 1000)], memo: "",
                             segments: [TxtSegment(range: sec(1000, 1010), text: "あ")])
        #expect(formatTxt(input([block])).contains("[00:00] あ"))
    }
}

struct FormatTimestampTests {
    @Test func minutesAndSeconds() {
        #expect(formatTimestamp(ms: 65_000, withHours: false) == "01:05")
        #expect(formatTimestamp(ms: 59_999, withHours: false) == "00:59")
        #expect(formatTimestamp(ms: 3_725_000, withHours: true) == "1:02:05")
        #expect(formatTimestamp(ms: -5, withHours: false) == "00:00")
    }
}

struct ExportFileNameTests {
    @Test func dateAndName() {
        #expect(exportFileName(recordedAt: recordedAt, name: "ブロック 1", ext: "mp3", timeZone: tokyo)
            == "20261011_ブロック 1.mp3")
    }

    @Test func replacesInvalidCharacters() {
        #expect(exportFileName(recordedAt: recordedAt, name: " a/b:c\nd ", ext: "txt", timeZone: tokyo)
            == "20261011_a_b_c_d.txt")
        #expect(exportFileName(recordedAt: recordedAt, name: "..隠し", ext: "txt", timeZone: tokyo)
            == "20261011_隠し.txt")
    }

    @Test func emptyNameUsesDateOnly() {
        #expect(exportFileName(recordedAt: recordedAt, name: "  ", ext: "mp3", timeZone: tokyo) == "20261011.mp3")
    }

    @Test func avoidsTakenNames() {
        let taken: Set = ["20261011_A.mp3", "20261011_A_2.mp3"]
        #expect(exportFileName(recordedAt: recordedAt, name: "A", ext: "mp3", taken: taken, timeZone: tokyo)
            == "20261011_A_3.mp3")
    }

    @Test func truncatesLongNames() {
        let name = String(repeating: "あ", count: 100)
        #expect(exportFileName(recordedAt: recordedAt, name: name, ext: "txt", timeZone: tokyo)
            == "20261011_" + String(repeating: "あ", count: 60) + ".txt")
    }
}
