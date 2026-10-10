import AVFoundation

/// 長さ、サンプルレート、チャンネル数、録音日時を返す。音声データ自体は読まない
public func audioInfo(of url: URL) async throws -> AudioInfo {
    let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
    guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
        throw AudioIOError.noAudioTrack
    }
    let duration = try await asset.load(.duration)
    let descriptions = try await track.load(.formatDescriptions)
    guard let desc = descriptions.first,
          let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc)?.pointee else {
        throw AudioIOError.unreadable("format description")
    }
    let ms = Int((duration.seconds * 1000).rounded())
    let recordedAt = try? await asset.load(.creationDate)?.load(.dateValue)
    return AudioInfo(durationMs: ms, sampleRate: asbd.mSampleRate, channels: Int(asbd.mChannelsPerFrame),
                     recordedAt: recordedAt)
}
