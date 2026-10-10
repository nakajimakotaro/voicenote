import Domain
import Foundation
import Testing
@testable import AudioIO

private func tmpMp3() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("render-\(UUID()).mp3")
}

struct Mp3RendererTests {
    @Test func joinsRangesForTranscription() async throws {
        let out = tmpMp3()
        defer { try? FileManager.default.removeItem(at: out) }

        let result = try await renderMp3(input: speechURL, ranges: [speechA, speechB], output: out,
                                         sampleRate: 16_000, kbps: 48, fadeMs: 20)
        let expectedMs = speechA.durationMs + speechB.durationMs
        #expect(abs(result.durationMs - expectedMs) <= 5)
        // CBRなので大きさは長さ×ビットレートにほぼ比例する
        let expectedBytes = Double(expectedMs) / 1000 * 48_000 / 8
        #expect(abs(Double(result.bytes) - expectedBytes) < expectedBytes * 0.1)
        #expect(try FileManager.default.attributesOfItem(atPath: out.path)[.size] as? Int == result.bytes)

        // LAMEタグがあるので、読み込む側も同じ長さとして扱える
        let info = try await audioInfo(of: out)
        #expect(info.sampleRate == 16_000)
        #expect(info.channels == 1)
        #expect(abs(info.durationMs - result.durationMs) <= 60)
    }

    /// 16kHz・32kbpsはフレームが小さくてLAMEタグが入らない。エンコーダーの遅延の分（約0.1秒）だけ長く読まれる
    @Test func lowBitrateWithoutTag() async throws {
        let out = tmpMp3()
        defer { try? FileManager.default.removeItem(at: out) }
        let result = try await renderMp3(input: speechURL, ranges: [speechA], output: out,
                                         sampleRate: 16_000, kbps: 32, fadeMs: 20)
        let info = try await audioInfo(of: out)
        #expect(info.durationMs >= result.durationMs)
        #expect(info.durationMs - result.durationMs <= 150)
    }

    @Test func cutsExactlyTheRequestedRange() async throws {
        let wav = try makeSineWav(seconds: 3, sampleRate: 48_000, channels: 2)
        let out = tmpMp3()
        defer {
            try? FileManager.default.removeItem(at: wav)
            try? FileManager.default.removeItem(at: out)
        }

        let result = try await renderMp3(input: wav, ranges: [TimeRange(startMs: 500, endMs: 1_500)], output: out,
                                         sampleRate: 44_100, kbps: 64, fadeMs: 30)
        #expect(result.durationMs == 1_000)
        let info = try await audioInfo(of: out)
        #expect(info.sampleRate == 44_100)
        #expect(abs(info.durationMs - 1_000) <= 60)
    }

    @Test func skipsEmptyRanges() async throws {
        let out = tmpMp3()
        defer { try? FileManager.default.removeItem(at: out) }
        let result = try await renderMp3(input: speechURL, ranges: [TimeRange(startMs: 3_000, endMs: 3_000), speechA],
                                         output: out, sampleRate: 16_000, kbps: 32, fadeMs: 0)
        #expect(abs(result.durationMs - speechA.durationMs) <= 5)
    }

    @Test func cancellingRemovesOutput() async throws {
        let out = tmpMp3()
        let task = Task {
            try await renderMp3(input: speechURL, ranges: [TimeRange(startMs: 0, endMs: 17_000)], output: out,
                                sampleRate: 16_000, kbps: 32, fadeMs: 20)
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!FileManager.default.fileExists(atPath: out.path))
    }
}

struct FadeTests {
    @Test func fadesInAcrossChunks() {
        var fade = Fade(samples: 4)
        var a: [Float] = [1, 1, 1]
        var b: [Float] = [1, 1, 1]
        fade.applyIn(&a)
        fade.applyIn(&b)
        #expect(a == [0, 0.25, 0.5])
        #expect(b == [0.75, 1, 1])
    }

    @Test func fadesOutAtTheEnd() {
        let fade = Fade(samples: 4)
        var chunk: [Float] = [1, 1, 1, 1, 1, 1]
        fade.applyOut(&chunk)
        #expect(chunk == [1, 1, 0.75, 0.5, 0.25, 0])
    }

    @Test func zeroSamplesDoesNothing() {
        var fade = Fade(samples: 0)
        var chunk: [Float] = [1, 1]
        fade.applyIn(&chunk)
        fade.applyOut(&chunk)
        #expect(chunk == [1, 1])
    }
}
