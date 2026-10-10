import Domain
import Testing
@testable import AudioIO

struct VADSegmenterTests {
    let params = VADParams(threshold: 0.5, negThreshold: 0.35, minSpeechMs: 250, minSilenceMs: 300, padMs: 100)

    /// 32msごとの確率列を流して、出てきた区間を集める
    func run(_ probs: [Float], params: VADParams? = nil) -> [TimeRange] {
        var seg = VADSegmenter(params: params ?? self.params)
        var out: [TimeRange] = []
        for (i, p) in probs.enumerated() {
            if let r = seg.push(prob: p, startMs: i * 32, endMs: (i + 1) * 32) { out.append(r) }
        }
        if let r = seg.finish(totalMs: probs.count * 32) { out.append(r) }
        return out
    }

    func frames(_ value: Float, _ count: Int) -> [Float] { Array(repeating: value, count: count) }

    @Test func closesAfterMinSilenceAndPads() {
        // 無音10 → 発話20（640ms）→ 無音20
        let out = run(frames(0, 10) + frames(0.9, 20) + frames(0, 20))
        #expect(out == [TimeRange(startMs: 320 - 100, endMs: 960 + 100)])
    }

    @Test func shortPauseDoesNotSplit() {
        // 発話の途中に288msの無音（minSilence 300ms 未満）
        let out = run(frames(0.9, 10) + frames(0, 9) + frames(0.9, 10) + frames(0, 20))
        #expect(out.count == 1)
        #expect(out.first?.startMs == 0)
        #expect(out.first?.endMs == 29 * 32 + 100)
    }

    @Test func hysteresisKeepsSpeechBetweenThresholds() {
        // 0.4 は終了の閾値（0.35）より上なので無音として数えない
        let out = run(frames(0.9, 10) + frames(0.4, 30) + frames(0, 20))
        #expect(out == [TimeRange(startMs: 0, endMs: 40 * 32 + 100)])
    }

    @Test func dropsTooShortSpeech() {
        // 192ms の発話は minSpeech 250ms 未満
        #expect(run(frames(0, 10) + frames(0.9, 6) + frames(0, 20)).isEmpty)
    }

    @Test func paddingNeverOverlapsPreviousRegion() {
        let p = VADParams(threshold: 0.5, negThreshold: 0.35, minSpeechMs: 0, minSilenceMs: 64, padMs: 200)
        let out = run(frames(0.9, 10) + frames(0, 3) + frames(0.9, 10) + frames(0, 10), params: p)
        #expect(out.count == 2)
        #expect(out[0].endMs <= out[1].startMs)
    }

    @Test func finishClosesOpenRegionAtEnd() {
        let out = run(frames(0, 10) + frames(0.9, 20))
        #expect(out == [TimeRange(startMs: 220, endMs: 30 * 32)])
    }
}
