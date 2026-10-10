import Domain

/// VADの確率列から発話区間を作る。開始と終了で閾値を分け（ヒステリシス）、
/// 無音が `minSilenceMs` 続いたら区間を閉じる。状態はチェックポイントに保存できる
struct VADSegmenter: Codable, Equatable {
    var params: VADParams
    private var speechStartMs: Int?
    /// 確率が negThreshold を下回り始めた時刻（発話中のみ）
    private var silenceStartMs: Int?
    /// 直前に出した区間の終わり。パディングで重ならないようにする
    private var lastEndMs = 0

    init(params: VADParams) {
        self.params = params
    }

    /// 1フレーム分の確率を入れる。区間が閉じたら返す
    mutating func push(prob: Float, startMs: Int, endMs: Int) -> TimeRange? {
        if prob >= params.threshold {
            silenceStartMs = nil
            if speechStartMs == nil { speechStartMs = startMs }
            return nil
        }
        guard let speechStart = speechStartMs, prob < params.negThreshold else { return nil }
        let silenceStart = silenceStartMs ?? startMs
        silenceStartMs = silenceStart
        guard endMs - silenceStart >= params.minSilenceMs else { return nil }
        speechStartMs = nil
        silenceStartMs = nil
        return close(startMs: speechStart, endMs: silenceStart, totalMs: nil)
    }

    /// 音声の終わりで、開いている区間を閉じる
    mutating func finish(totalMs: Int) -> TimeRange? {
        guard let speechStart = speechStartMs else { return nil }
        let end = silenceStartMs ?? totalMs
        speechStartMs = nil
        silenceStartMs = nil
        return close(startMs: speechStart, endMs: end, totalMs: totalMs)
    }

    private mutating func close(startMs: Int, endMs: Int, totalMs: Int?) -> TimeRange? {
        guard endMs - startMs >= params.minSpeechMs else { return nil }
        let start = max(startMs - params.padMs, lastEndMs, 0)
        var end = endMs + params.padMs
        if let totalMs { end = min(end, totalMs) }
        lastEndMs = end
        return TimeRange(startMs: start, endMs: end)
    }
}
