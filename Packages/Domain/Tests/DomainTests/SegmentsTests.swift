import Testing
@testable import Domain

private func sec(_ s: Double, _ e: Double) -> TimeRange { TimeRange(startMs: Int(s * 1000), endMs: Int(e * 1000)) }

/// 隙間なく、重ならず、ブロック全体を覆っているか
private func coversContiguously(_ segments: [TimeRange], _ block: TimeRange) -> Bool {
    guard let first = segments.first, let last = segments.last else { return false }
    return first.startMs == block.startMs && last.endMs == block.endMs
        && zip(segments, segments.dropFirst()).allSatisfy { $0.endMs == $1.startMs }
}

struct BuildSegmentsTests {
    @Test func shortBlockIsOneSegment() {
        let block = sec(10, 30)
        let segments = buildSegments(block: block, regions: [sec(11, 15), sec(18, 29)], maxMs: 30_000, quietestPoint: nil)
        #expect(segments == [block])
    }

    @Test func splitsAtMidpointOfSilence() {
        let block = sec(0, 60)
        let regions = [sec(1, 10), sec(12, 25), sec(31, 45), sec(48, 57)]
        let segments = buildSegments(block: block, regions: regions, maxMs: 30_000, quietestPoint: nil)
        // 0〜25までで25秒。31〜45を足すと45秒になるので、25と31の中点28で切る
        #expect(segments == [sec(0, 28), sec(28, 60)])
        #expect(coversContiguously(segments, block))
    }

    @Test func manyShortUtterances() {
        let block = sec(0, 300)
        let regions = stride(from: 0.0, to: 300, by: 7).map { sec($0 + 1, min($0 + 5, 300)) }
        let segments = buildSegments(block: block, regions: regions, maxMs: 30_000, quietestPoint: nil)
        #expect(coversContiguously(segments, block))
        // 発話のあいだの無音は3秒なので、超えても中点までの1.5秒だけ
        #expect(segments.allSatisfy { $0.durationMs <= 30_000 + 1_500 })
        #expect(segments.count >= 10)
    }

    @Test func longUtteranceCutAtQuietestPoint() {
        let block = sec(0, 70)
        var asked: [TimeRange] = []
        let segments = buildSegments(block: block, regions: [sec(0, 70)], maxMs: 30_000) { window in
            asked.append(window)
            return window.startMs + 2_000
        }
        // 後半の範囲（15〜30秒）を渡し、その中の静かな点（17秒）で切る
        #expect(asked.first == sec(15, 30))
        #expect(segments == [sec(0, 17), sec(17, 34), sec(34, 51), sec(51, 70)])
    }

    @Test func longUtteranceWithoutPeaksCutsAtMax() {
        let segments = buildSegments(block: sec(0, 70), regions: [sec(0, 70)], maxMs: 30_000, quietestPoint: nil)
        #expect(segments == [sec(0, 30), sec(30, 60), sec(60, 70)])
    }

    @Test func quietestPointOutsideWindowIsClamped() {
        let segments = buildSegments(block: sec(0, 40), regions: [sec(0, 40)], maxMs: 30_000) { _ in 999_999 }
        #expect(segments == [sec(0, 30), sec(30, 40)])
    }

    @Test func longUtteranceInsideBlockWithOthers() {
        let block = sec(0, 80)
        let regions = [sec(2, 8), sec(10, 50), sec(55, 60)]
        let segments = buildSegments(block: block, regions: regions, maxMs: 30_000, quietestPoint: nil)
        // 10〜50の発話は10〜40と40〜50に分かれる。2〜8のあとに10〜40は入らないので中点9で切る
        #expect(segments == [sec(0, 9), sec(9, 40), sec(40, 80)])
        #expect(coversContiguously(segments, block))
    }

    @Test func regionsOutsideBlockAreIgnoredAndClipped() {
        let block = sec(10, 50)
        let regions = [sec(0, 5), sec(8, 20), sec(30, 45), sec(60, 70)]
        let segments = buildSegments(block: block, regions: regions, maxMs: 30_000, quietestPoint: nil)
        // ブロック内は10〜20と30〜45。10から45は35秒なので、20と30の中点25で切る
        #expect(segments == [sec(10, 25), sec(25, 50)])
    }

    @Test func blockWithoutSpeechIsTreatedAsOneUtterance() {
        let segments = buildSegments(block: sec(0, 45), regions: [], maxMs: 30_000, quietestPoint: nil)
        #expect(segments == [sec(0, 30), sec(30, 45)])
    }

    @Test func overlappingRegionsAreMerged() {
        let segments = buildSegments(block: sec(0, 40), regions: [sec(0, 20), sec(15, 25), sec(25, 40)],
                                     maxMs: 30_000, quietestPoint: nil)
        // 0〜40の1つの発話としてmaxMsで切る
        #expect(segments == [sec(0, 30), sec(30, 40)])
    }

    @Test func emptyBlock() {
        #expect(buildSegments(block: sec(5, 5), regions: [sec(0, 10)], maxMs: 30_000, quietestPoint: nil).isEmpty)
    }
}

struct UncoveredRangesTests {
    @Test func fullyCovered() {
        #expect(uncoveredRanges(block: sec(0, 60), covered: [sec(0, 30), sec(30, 60)]).isEmpty)
    }

    @Test func gapsAtEdgesAndBetween() {
        let gaps = uncoveredRanges(block: sec(0, 100), covered: [sec(40, 60), sec(10, 30)])
        #expect(gaps == [sec(0, 10), sec(30, 40), sec(60, 100)])
    }

    @Test func noSegments() {
        #expect(uncoveredRanges(block: sec(5, 20), covered: []) == [sec(5, 20)])
    }
}

struct CostTests {
    @Test func perMinute() {
        #expect(abs(estimateUsd(totalMs: 5 * 3_600_000, pricePerMinUsd: 0.006) - 1.8) < 1e-9)
        #expect(estimateUsd(totalMs: 30_000, pricePerMinUsd: 0.006) == 0.003)
        #expect(estimateUsd(totalMs: -1, pricePerMinUsd: 0.006) == 0)
    }
}
