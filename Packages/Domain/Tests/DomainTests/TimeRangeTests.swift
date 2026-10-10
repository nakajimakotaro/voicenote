import Testing
@testable import Domain

struct TimeRangeTests {
    @Test func duration() {
        #expect(TimeRange(startMs: 1_000, endMs: 4_500).durationMs == 3_500)
        #expect(TimeRange(startMs: 5_000, endMs: 4_000).durationMs == 0)
        #expect(TimeRange(startMs: 5_000, endMs: 5_000).isEmpty)
    }

    @Test func containsIsHalfOpen() {
        let r = TimeRange(startMs: 100, endMs: 200)
        #expect(r.contains(100))
        #expect(r.contains(199))
        #expect(!r.contains(200))
        #expect(!r.contains(99))
    }

    @Test func touchingRangesDoNotOverlap() {
        let a = TimeRange(startMs: 0, endMs: 100)
        #expect(!a.overlaps(TimeRange(startMs: 100, endMs: 200)))
        #expect(a.overlaps(TimeRange(startMs: 99, endMs: 200)))
        #expect(a.intersection(TimeRange(startMs: 100, endMs: 200)) == nil)
        #expect(a.intersection(TimeRange(startMs: 50, endMs: 200)) == TimeRange(startMs: 50, endMs: 100))
    }
}
