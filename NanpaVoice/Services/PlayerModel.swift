import AVFoundation
import Foundation
import Observation

/// 元の音声ファイルをそのまま再生する。ブロックごとに音声を切り出さず、シークして区間を再生する
@MainActor
@Observable
final class PlayerModel {
    static let rates: [Float] = [1.0, 1.25, 1.5, 2.0]

    private(set) var isPlaying = false
    /// 再生位置（元音声の先頭からのミリ秒）。止めている間はカーソルとして使う
    private(set) var positionMs = 0
    private(set) var errorMessage: String?
    var rate: Float = 1.0 {
        didSet { player?.rate = rate }
    }

    private var player: AVAudioPlayer?
    private var url: URL?
    /// ここまで来たら止める（区間の試聴）
    private var stopAtMs: Int?
    private var ticker: Task<Void, Never>?

    /// 再生する音声ファイルを設定する。同じファイルなら何もしない
    func load(url: URL) {
        guard self.url != url else { return }
        stop()
        self.url = url
        player = nil
    }

    /// `ms` から再生する。`until` を指定するとそこで止まる
    func play(from ms: Int, until: Int? = nil) {
        guard let player = preparedPlayer() else { return }
        player.currentTime = Double(max(0, ms)) / 1000
        positionMs = max(0, ms)
        stopAtMs = until
        player.rate = rate
        guard player.play() else {
            errorMessage = "再生できませんでした"
            return
        }
        isPlaying = true
        startTicker()
    }

    /// 止めた位置から再開する
    func resume() {
        play(from: positionMs, until: stopAtMs.flatMap { $0 > positionMs ? $0 : nil })
    }

    func pause() {
        player?.pause()
        if let player { positionMs = Int(player.currentTime * 1000) }
        isPlaying = false
        ticker?.cancel()
        ticker = nil
    }

    func toggle() {
        isPlaying ? pause() : resume()
    }

    /// 再生中なら位置を変えて続け、止めていればカーソルだけ動かす
    func seek(to ms: Int) {
        let clamped = max(0, ms)
        positionMs = clamped
        player?.currentTime = Double(clamped) / 1000
    }

    func stop() {
        pause()
        stopAtMs = nil
    }

    private func preparedPlayer() -> AVAudioPlayer? {
        if let player { return player }
        guard let url else { return nil }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
            try AVAudioSession.sharedInstance().setActive(true)
            let player = try AVAudioPlayer(contentsOf: url)
            player.enableRate = true
            player.prepareToPlay()
            self.player = player
            errorMessage = nil
            return player
        } catch {
            errorMessage = "音声ファイルを開けませんでした"
            return nil
        }
    }

    /// 再生中は画面の更新に合わせて位置を読む
    private func startTicker() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                guard let self, let player = self.player else { return }
                self.positionMs = Int(player.currentTime * 1000)
                if let stopAt = self.stopAtMs, self.positionMs >= stopAt {
                    self.pause()
                    self.seek(to: stopAt)
                    self.stopAtMs = nil
                    return
                }
                if !player.isPlaying {
                    self.isPlaying = false
                    self.ticker = nil
                    return
                }
            }
        }
    }
}
