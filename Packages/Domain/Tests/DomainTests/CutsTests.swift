import Testing
@testable import Domain

private func sec(_ s: Double, _ e: Double) -> TimeRange { TimeRange(startMs: Int(s * 1000), endMs: Int(e * 1000)) }

struct NormalizeCutsTests {
    @Test func clampsToBlockAndMergesOverlappingAndTouching() {
        let block = sec(10, 100)
        let cuts = [sec(50, 60), sec(0, 15), sec(55, 70), sec(70, 75), sec(95, 200), sec(30, 30)]
        #expect(normalizeCuts(block: block, cuts: cuts) == [sec(10, 15), sec(50, 75), sec(95, 100)])
    }

    @Test func dropsCutsOutsideBlock() {
        #expect(normalizeCuts(block: sec(10, 20), cuts: [sec(0, 10), sec(20, 30)]).isEmpty)
    }
}

struct KeepRangesTests {
    @Test func noCutsKeepsWholeBlock() {
        #expect(keepRanges(block: sec(10, 20), cuts: []) == [sec(10, 20)])
    }

    @Test func removesCutsIncludingEdges() {
        let ranges = keepRanges(block: sec(0, 100), cuts: [sec(40, 50), sec(0, 10), sec(90, 120)])
        #expect(ranges == [sec(10, 40), sec(50, 90)])
    }

    @Test func wholeBlockCut() {
        #expect(keepRanges(block: sec(0, 10), cuts: [sec(0, 10)]).isEmpty)
    }
}

struct ToEditedMsTests {
    let cuts = [sec(10, 20), sec(30, 35)]

    @Test func beforeFirstCutIsUnchanged() {
        #expect(toEditedMs(5_000, cuts: cuts) == 5_000)
        #expect(toEditedMs(10_000, cuts: cuts) == 10_000)
    }

    @Test func subtractsEarlierCuts() {
        #expect(toEditedMs(25_000, cuts: cuts) == 15_000)
        #expect(toEditedMs(40_000, cuts: cuts) == 25_000)
    }

    @Test func insideCutSnapsToCutStart() {
        #expect(toEditedMs(15_000, cuts: cuts) == 10_000)
        #expect(toEditedMs(33_000, cuts: cuts) == 20_000)
        #expect(toEditedMs(20_000, cuts: cuts) == 10_000)
    }
}

struct VisibilityTests {
    let cuts = [sec(10, 20), sec(30, 40)]

    @Test func untouchedSegmentIsFull() {
        #expect(visibility(of: sec(0, 10), cuts: cuts) == .full)
        #expect(visibility(of: sec(20, 30), cuts: cuts) == .full)
    }

    @Test func coveredSegmentIsHidden() {
        #expect(visibility(of: sec(12, 18), cuts: cuts) == .hidden)
        #expect(visibility(of: sec(30, 40), cuts: cuts) == .hidden)
    }

    @Test func partlyCutSegmentStartsAtKeptPart() {
        #expect(visibility(of: sec(5, 15), cuts: cuts) == .partial(keptStartMs: 5_000))
        #expect(visibility(of: sec(15, 25), cuts: cuts) == .partial(keptStartMs: 20_000))
        #expect(visibility(of: sec(15, 45), cuts: cuts) == .partial(keptStartMs: 20_000))
    }
}

struct UncutTests {
    @Test func removesMiddleOfCut() {
        #expect(uncut(sec(12, 15), cuts: [sec(10, 20)]) == [sec(10, 12), sec(15, 20)])
    }

    @Test func removesWholeCutsInRange() {
        #expect(uncut(sec(0, 50), cuts: [sec(10, 20), sec(30, 40), sec(60, 70)]) == [sec(60, 70)])
    }

    @Test func trimsEdges() {
        #expect(uncut(sec(15, 35), cuts: [sec(10, 20), sec(30, 40)]) == [sec(10, 15), sec(35, 40)])
    }
}

struct FindRangeTests {
    let ranges = [sec(0, 10), sec(10, 20), sec(30, 40)]

    @Test func findsContainingRange() {
        #expect(indexOfRange(containing: 0, in: ranges) == 0)
        #expect(indexOfRange(containing: 10_000, in: ranges) == 1)
        #expect(indexOfRange(containing: 39_999, in: ranges) == 2)
    }

    @Test func gapsAndOutsideReturnNil() {
        #expect(indexOfRange(containing: 25_000, in: ranges) == nil)
        #expect(indexOfRange(containing: 40_000, in: ranges) == nil)
        #expect(indexOfRange(containing: -1, in: ranges) == nil)
        #expect(indexOfRange(containing: 0, in: []) == nil)
    }

    @Test func cutContaining() {
        #expect(cut(containing: 35_000, in: ranges) == sec(30, 40))
        #expect(cut(containing: 25_000, in: ranges) == nil)
    }
}

struct EditHistoryTests {
    @Test func undoAndRedoInOrder() {
        var history = EditHistory<Int>()
        #expect(!history.canUndo && !history.canRedo)
        history.record(1)
        history.record(2)
        #expect(history.undo() == 2)
        #expect(history.undo() == 1)
        #expect(history.undo() == nil)
        #expect(history.redo() == 1)
        #expect(history.canUndo && history.canRedo)
        #expect(history.redo() == 2)
        #expect(history.redo() == nil)
    }

    @Test func recordingClearsRedo() {
        var history = EditHistory<Int>()
        history.record(1)
        _ = history.undo()
        history.record(2)
        #expect(!history.canRedo)
        #expect(history.undo() == 2)
    }
}
