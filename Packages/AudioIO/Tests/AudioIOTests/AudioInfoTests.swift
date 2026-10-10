import AVFoundation
import Foundation
import Testing
@testable import AudioIO

struct AudioInfoTests {
    @Test func readsWavInfo() async throws {
        let url = try makeSineWav(seconds: 2.5, sampleRate: 44_100, channels: 2)
        defer { try? FileManager.default.removeItem(at: url) }

        let info = try await audioInfo(of: url)
        #expect(abs(info.durationMs - 2_500) <= 1)
        #expect(info.sampleRate == 44_100)
        #expect(info.channels == 2)
    }

    @Test func rejectsNonAudioFile() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).txt")
        try Data("not audio".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        await #expect(throws: (any Error).self) { try await audioInfo(of: url) }
    }
}

/// テスト用の440Hzのサイン波wavを一時フォルダに作る
func makeSineWav(seconds: Double, sampleRate: Double, channels: AVAudioChannelCount) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).wav")
    let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels)!
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    let frames = AVAudioFrameCount(seconds * sampleRate)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    buffer.frameLength = frames
    for ch in 0..<Int(channels) {
        let data = buffer.floatChannelData![ch]
        for i in 0..<Int(frames) {
            data[i] = 0.3 * sin(2 * .pi * 440 * Float(i) / Float(sampleRate))
        }
    }
    try file.write(from: buffer)
    return url
}
