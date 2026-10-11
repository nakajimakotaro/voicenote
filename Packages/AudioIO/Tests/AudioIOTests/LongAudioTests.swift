import Darwin
import Domain
import Foundation
import Testing
@testable import AudioIO

/// 長い録音を通しで処理する確認。普段は動かさず、環境変数で録音を渡したときだけ動く
///
///     LONG_AUDIO=/path/to/5h.m4a swift test --filter LongAudioTests
///
/// かかった時間とメモリの最大使用量（iOSのメモリ制限と同じ phys_footprint）を出力する
@Suite(.enabled(if: ProcessInfo.processInfo.environment["LONG_AUDIO"] != nil), .serialized)
struct LongAudioTests {
    let input = URL(fileURLWithPath: ProcessInfo.processInfo.environment["LONG_AUDIO"] ?? "")

    @Test func analyzeWholeRecording() async throws {
        let (files, dir) = try makeFiles()
        defer { try? FileManager.default.removeItem(at: dir) }
        let info = try await audioInfo(of: input)

        let clock = ContinuousClock()
        let elapsed = try await clock.measure {
            try await analyze(input: input, files: files, vad: VADParams()) { _ in }
        }

        let regions = try readRegions(from: files.regions)
        let blocks = buildBlocks(regions: regions, gapMs: 30_000, minBlockMs: 20_000, manual: [])
        let peaks50 = try PeakFile(url: files.peaks50)
        let peaks1 = try PeakFile(url: files.peaks1)
        print("""
            [LongAudio] 解析 \(Format.ms(info.durationMs)) を \(Format.seconds(elapsed)) で処理（\(Format.speed(info.durationMs, elapsed))）
            [LongAudio] 発話区間 \(regions.count) 個、ブロック \(blocks.count) 個、ピーク \(peaks50.count) / \(peaks1.count)
            [LongAudio] メモリの最大 \(Format.mb(maxFootprint()))
            """)
        #expect(abs(peaks50.count - info.durationMs / PeakFile.msPerPeak50) <= 1)
        #expect(abs(peaks1.count - info.durationMs / PeakFile.msPerPeak1) <= 1)
        #expect(!blocks.isEmpty)
    }

    /// 書き出しで一番重いのは長いブロックのmp3。先頭1時間を44.1kHzで書き出す
    @Test func renderOneHourMp3() async throws {
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("long-\(UUID()).mp3")
        defer { try? FileManager.default.removeItem(at: out) }
        let range = TimeRange(startMs: 0, endMs: 3_600_000)

        let clock = ContinuousClock()
        var result: Mp3Result?
        let elapsed = try await clock.measure {
            result = try await renderMp3(input: input, ranges: [range], output: out,
                                         sampleRate: 44_100, kbps: 64, fadeMs: 30)
        }
        print("""
            [LongAudio] mp3 1時間を \(Format.seconds(elapsed)) で書き出し（\(Format.speed(range.durationMs, elapsed))）、\
            \(Format.mb(UInt64(result?.bytes ?? 0)))
            [LongAudio] メモリの最大 \(Format.mb(maxFootprint()))
            """)
        #expect(abs((result?.durationMs ?? 0) - range.durationMs) <= 5)
    }
}

/// このプロセスのメモリ使用量の最大値（phys_footprint）
private func maxFootprint() -> UInt64 {
    var usage = rusage_info_v4()
    let ok = withUnsafeMutablePointer(to: &usage) {
        $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
            proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0) == 0
        }
    }
    return ok ? usage.ri_lifetime_max_phys_footprint : 0
}

private enum Format {
    static func ms(_ ms: Int) -> String { String(format: "%d:%02d:%02d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60) }
    static func mb(_ bytes: UInt64) -> String { String(format: "%.1fMB", Double(bytes) / 1_048_576) }
    static func seconds(_ d: Duration) -> String { String(format: "%.1f秒", d / .seconds(1)) }
    static func speed(_ ms: Int, _ d: Duration) -> String {
        String(format: "実時間の%.0f倍", Double(ms) / 1000 / (d / .seconds(1)))
    }
}
