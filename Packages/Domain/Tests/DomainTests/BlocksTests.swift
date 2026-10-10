import Testing
@testable import Domain

private func r(_ s: Int, _ e: Int) -> TimeRange { TimeRange(startMs: s, endMs: e) }
private func sec(_ s: Double, _ e: Double) -> TimeRange { r(Int(s * 1000), Int(e * 1000)) }

struct BuildBlocksTests {
    @Test func joinsRegionsSeparatedByLessThanGap() {
        let regions = [sec(0, 10), sec(20, 40), sec(100, 130), sec(135, 140)]
        let blocks = buildBlocks(regions: regions, gapMs: 30_000, minBlockMs: 20_000, manual: [])
        #expect(blocks.map(\.range) == [sec(0, 40), sec(100, 140)])
        #expect(blocks.allSatisfy { !$0.manuallyEdited })
    }

    @Test func gapExactlyEqualSplits() {
        let blocks = buildBlocks(regions: [sec(0, 30), sec(60, 90)], gapMs: 30_000, minBlockMs: 0, manual: [])
        #expect(blocks.count == 2)
    }

    @Test func shortBlocksAreExcluded() {
        let blocks = buildBlocks(regions: [sec(0, 5), sec(100, 130)], gapMs: 30_000, minBlockMs: 20_000, manual: [])
        #expect(blocks.map(\.status) == [.excluded, .candidate])
    }

    @Test func sortsAndHandlesOverlappingRegions() {
        let blocks = buildBlocks(regions: [sec(20, 30), sec(0, 25), sec(5, 10)], gapMs: 1_000, minBlockMs: 0, manual: [])
        #expect(blocks.map(\.range) == [sec(0, 30)])
    }

    @Test func emptyRegions() {
        #expect(buildBlocks(regions: [], gapMs: 30_000, minBlockMs: 20_000, manual: []).isEmpty)
    }

    @Test func manualBlocksAreKeptAndOverlappingRegionsSkipped() {
        let manual = BlockDraft(range: sec(50, 80), status: .selected, manuallyEdited: true)
        let regions = [sec(0, 10), sec(45, 55), sec(60, 70), sec(90, 120)]
        let blocks = buildBlocks(regions: regions, gapMs: 30_000, minBlockMs: 0, manual: [manual])
        // 45〜55は手動ブロックに重なるので外れる。0〜10と90〜120は手動ブロックをまたいでつながらない
        #expect(blocks.map(\.range) == [sec(0, 10), sec(50, 80), sec(90, 120)])
        #expect(blocks[1] == manual)
    }

    @Test func autoBlocksNeverOverlapManual() {
        let manual = [BlockDraft(range: sec(12, 14), status: .candidate, manuallyEdited: true),
                      BlockDraft(range: sec(30, 31), status: .excluded, manuallyEdited: true)]
        let regions = stride(from: 0, to: 60, by: 3).map { sec(Double($0), Double($0) + 2) }
        let blocks = buildBlocks(regions: regions, gapMs: 5_000, minBlockMs: 0, manual: manual)
        for (i, a) in blocks.enumerated() {
            for b in blocks[(i + 1)...] { #expect(!a.range.overlaps(b.range)) }
        }
        #expect(blocks.filter(\.manuallyEdited).count == 2)
    }
}

struct BlockEditTests {
    let blocks = [r(1_000, 5_000), r(8_000, 12_000), r(20_000, 30_000)]

    @Test func startEdgeLimits() {
        #expect(boundaryLimits(of: 1, edge: .start, in: blocks, totalMs: 40_000, minLengthMs: 1_000) == 5_000...11_000)
        #expect(boundaryLimits(of: 0, edge: .start, in: blocks, totalMs: 40_000, minLengthMs: 1_000) == 0...4_000)
    }

    @Test func endEdgeLimits() {
        #expect(boundaryLimits(of: 1, edge: .end, in: blocks, totalMs: 40_000, minLengthMs: 1_000) == 9_000...20_000)
        #expect(boundaryLimits(of: 2, edge: .end, in: blocks, totalMs: 40_000, minLengthMs: 1_000) == 21_000...40_000)
    }

    @Test func tooShortBlockCannotMove() {
        let tiny = [r(0, 500)]
        #expect(boundaryLimits(of: 0, edge: .start, in: tiny, totalMs: 1_000, minLengthMs: 1_000) == 0...0)
    }

    @Test func split() {
        #expect(splitRange(r(0, 10_000), at: 4_000, minLengthMs: 1_000)! == (r(0, 4_000), r(4_000, 10_000)))
        #expect(splitRange(r(0, 10_000), at: 500, minLengthMs: 1_000) == nil)
        #expect(splitRange(r(0, 10_000), at: 9_500, minLengthMs: 1_000) == nil)
    }
}

struct TimelineRowsTests {
    @Test func splitsAcrossRows() {
        let pieces = splitIntoRows([r(500, 2_500)], rowMs: 1_000)
        #expect(pieces.map(\.row) == [0, 1, 2])
        #expect(pieces.map(\.startMs) == [500, 1_000, 2_000])
        #expect(pieces.map(\.endMs) == [1_000, 2_000, 2_500])
        #expect(pieces.allSatisfy { $0.source == r(500, 2_500) })
        #expect(pieces.map(\.containsStart) == [true, false, false])
        #expect(pieces.map(\.containsEnd) == [false, false, true])
    }

    @Test func endingOnRowBoundaryStaysInRow() {
        let pieces = splitIntoRows([r(0, 1_000), r(1_000, 1_200)], rowMs: 1_000)
        #expect(pieces.map(\.row) == [0, 1])
    }

    @Test func skipsEmpty() {
        #expect(splitIntoRows([r(5, 5)], rowMs: 1_000).isEmpty)
    }

    @Test func rows() {
        #expect(rowCount(totalMs: 5 * 3_600_000, rowMs: 600_000) == 30)
        #expect(rowCount(totalMs: 600_001, rowMs: 600_000) == 2)
        #expect(rowCount(totalMs: 0, rowMs: 600_000) == 1)
    }
}
