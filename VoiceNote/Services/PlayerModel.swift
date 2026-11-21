import AVFoundation
import Domain
import Foundation
import MediaPlayer
import Observation

/// 元の音声ファイルをそのまま再生する。ブロックごとに音声を切り出さず、シークして区間を再生する。
/// 画面を消しても再生を続け、ロック画面やコントロールセンターから操作できる
@MainActor
@Observable
final class PlayerModel {
    static let rates: [Float] = [1.0, 1.25, 1.5, 2.0]

    private(set) var isPlaying = false
    /// 再生位置（元音声の先頭からのミリ秒）。止めている間はカーソルとして使う
    private(set) var positionMs = 0
    private(set) var errorMessage: String?
    var rate: Float = 1.0 {
        didSet {
            player?.rate = rate
            updateNowPlaying()
        }
    }
    /// 飛ばすカット（正規化済み）。再生位置がカットに入った瞬間にカットの終わりへ飛ぶ
    private(set) var cuts: [TimeRange] = []

    private var player: AVAudioPlayer?
    private var url: URL?
    /// ロック画面に出す題名
    private var title = ""
    /// ここまで来たら止める（区間の試聴）
    private var stopAtMs: Int?
    private var ticker: Task<Void, Never>?

    /// 再生する音声ファイルを設定する。同じファイルなら何もしない
    func load(url: URL, title: String) {
        self.title = title
        guard self.url != url else { return }
        stop()
        self.url = url
        player = nil
    }

    func setCuts(_ cuts: [TimeRange]) {
        self.cuts = cuts
    }

    /// `ms` から再生する。`until` を指定するとそこで止まる
    func play(from ms: Int, until: Int? = nil) {
        guard let player = preparedPlayer() else { return }
        var start = max(0, ms)
        if let cut = activeCut(at: start) { start = cut.endMs }
        if let until, start >= until { return }
        player.currentTime = Double(start) / 1000
        positionMs = start
        stopAtMs = until
        player.rate = rate
        guard player.play() else {
            errorMessage = "再生できませんでした"
            return
        }
        isPlaying = true
        RemoteControl.shared.attach(self)
        updateNowPlaying()
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
        updateNowPlaying()
    }

    func toggle() {
        isPlaying ? pause() : resume()
    }

    /// 再生中なら位置を変えて続け、止めていればカーソルだけ動かす
    func seek(to ms: Int) {
        let clamped = max(0, ms)
        positionMs = clamped
        player?.currentTime = Double(clamped) / 1000
        updateNowPlaying()
    }

    func stop() {
        pause()
        stopAtMs = nil
        RemoteControl.shared.detach(self)
    }

    /// ロック画面の表示を今の状態に合わせる。再生中の位置は rate から OS が進めるので、毎回は送らない
    private func updateNowPlaying() {
        guard RemoteControl.shared.isAttached(self), let player else { return }
        RemoteControl.shared.setNowPlaying([
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyPlaybackDuration: player.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: Double(positionMs) / 1000,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? Double(rate) : 0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: Double(rate),
        ])
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

    private func activeCut(at ms: Int) -> TimeRange? {
        cut(containing: ms, in: cuts)
    }

    /// 次に読む位置までの待ち時間。次のカットが近ければ、その手前で起きる
    private func tickInterval() -> Duration {
        let tickMs = 50
        guard let next = cuts.first(where: { $0.startMs > positionMs }) else { return .milliseconds(tickMs) }
        let untilCut = Int(Double(next.startMs - positionMs) / Double(max(rate, 0.1)))
        return .milliseconds(min(tickMs, max(5, untilCut)))
    }

    /// 再生中は画面の更新に合わせて位置を読む
    private func startTicker() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: self?.tickInterval() ?? .milliseconds(50))
                guard let self, let player = self.player else { return }
                self.positionMs = Int(player.currentTime * 1000)
                if let cut = self.activeCut(at: self.positionMs) {
                    self.positionMs = cut.endMs
                    player.currentTime = Double(cut.endMs) / 1000
                    self.updateNowPlaying()
                }
                if let stopAt = self.stopAtMs, self.positionMs >= stopAt {
                    self.pause()
                    self.seek(to: stopAt)
                    self.stopAtMs = nil
                    return
                }
                // 最後まで再生した、または電話などで止められた
                if !player.isPlaying {
                    self.isPlaying = false
                    self.ticker = nil
                    self.updateNowPlaying()
                    return
                }
            }
        }
    }
}

/// ロック画面・コントロールセンター・イヤホンからの操作を、最後に再生した PlayerModel に渡す。
/// 画面ごとに PlayerModel があるので、操作先は1つに絞る
@MainActor
private final class RemoteControl {
    static let shared = RemoteControl()
    static let skipSeconds = 10

    private weak var owner: PlayerModel?
    private var targets: [(MPRemoteCommand, Any)] = []

    func isAttached(_ player: PlayerModel) -> Bool { owner === player }

    func attach(_ player: PlayerModel) {
        guard owner !== player else { return }
        removeTargets()
        owner = player
        let center = MPRemoteCommandCenter.shared()
        add(center.playCommand) { if !$0.isPlaying { $0.resume() } }
        add(center.pauseCommand) { if $0.isPlaying { $0.pause() } }
        add(center.togglePlayPauseCommand) { $0.toggle() }
        center.skipBackwardCommand.preferredIntervals = [NSNumber(value: Self.skipSeconds)]
        center.skipForwardCommand.preferredIntervals = [NSNumber(value: Self.skipSeconds)]
        add(center.skipBackwardCommand) { $0.seek(to: $0.positionMs - Self.skipSeconds * 1000) }
        add(center.skipForwardCommand) { $0.seek(to: $0.positionMs + Self.skipSeconds * 1000) }
    }

    func detach(_ player: PlayerModel) {
        guard owner === player else { return }
        removeTargets()
        owner = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    func setNowPlaying(_ info: [String: Any]) {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func add(_ command: MPRemoteCommand, _ action: @escaping @MainActor @Sendable (PlayerModel) -> Void) {
        command.isEnabled = true
        // 呼ばれるスレッドは決まっていないので、メインに移してから触る
        let target = command.addTarget { @Sendable [weak self] _ in
            Task { @MainActor in
                guard let owner = self?.owner else { return }
                action(owner)
            }
            return .success
        }
        targets.append((command, target))
    }

    private func removeTargets() {
        for (command, target) in targets {
            command.removeTarget(target)
            command.isEnabled = false
        }
        targets = []
    }
}
