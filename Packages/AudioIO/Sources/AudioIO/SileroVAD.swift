import CoreML
import Foundation

/// Silero VAD v5（16kHz）。512サンプル（32ms）ずつ入力し、発話の確率を返す。
/// 直前の入力の末尾64サンプルとLSTMの状態を次の入力に引き継ぐ
final class SileroVAD {
    static let sampleRate: Double = 16_000
    static let frameSamples = 512
    static let contextSamples = 64
    static let stateCount = 2 * 128

    private let model: MLModel
    private let audio: MLMultiArray
    private let lstm: MLMultiArray

    init() throws {
        guard let url = Bundle.module.url(forResource: "SileroVAD", withExtension: "mlmodelc") else {
            throw AudioIOError.unreadable("SileroVAD.mlmodelc")
        }
        let config = MLModelConfiguration()
        // 小さいモデルを32msごとに呼ぶので、Neural Engineへの受け渡しよりCPUのほうが速い
        config.computeUnits = .cpuOnly
        model = try MLModel(contentsOf: url, configuration: config)
        audio = try MLMultiArray(shape: [1, NSNumber(value: Self.contextSamples + Self.frameSamples)], dataType: .float32)
        lstm = try MLMultiArray(shape: [2, 1, 128], dataType: .float32)
        reset()
    }

    func reset() {
        fill(audio, with: 0)
        fill(lstm, with: 0)
    }

    /// チェックポイントに保存する内部状態（文脈64サンプル + LSTM 256個）
    var state: VADState {
        get {
            let a = audio.dataPointer.assumingMemoryBound(to: Float.self)
            let l = lstm.dataPointer.assumingMemoryBound(to: Float.self)
            return VADState(context: Array(UnsafeBufferPointer(start: a + Self.frameSamples, count: Self.contextSamples)),
                            lstm: Array(UnsafeBufferPointer(start: l, count: Self.stateCount)))
        }
        set {
            precondition(newValue.context.count == Self.contextSamples && newValue.lstm.count == Self.stateCount)
            let a = audio.dataPointer.assumingMemoryBound(to: Float.self)
            let l = lstm.dataPointer.assumingMemoryBound(to: Float.self)
            newValue.context.withUnsafeBufferPointer {
                a.advanced(by: Self.frameSamples).update(from: $0.baseAddress!, count: Self.contextSamples)
            }
            newValue.lstm.withUnsafeBufferPointer { l.update(from: $0.baseAddress!, count: Self.stateCount) }
        }
    }

    /// 512サンプルを入力して発話の確率（0〜1）を返す。足りない分は0で埋める
    func probability(_ frame: ArraySlice<Float>) throws -> Float {
        precondition(frame.count <= Self.frameSamples)
        let a = audio.dataPointer.assumingMemoryBound(to: Float.self)
        // 前回の入力の末尾64サンプルを先頭へ移して文脈にする
        a.update(from: a + Self.frameSamples, count: Self.contextSamples)
        frame.withUnsafeBufferPointer { a.advanced(by: Self.contextSamples).update(from: $0.baseAddress!, count: frame.count) }
        if frame.count < Self.frameSamples {
            a.advanced(by: Self.contextSamples + frame.count).update(repeating: 0, count: Self.frameSamples - frame.count)
        }

        let input = try MLDictionaryFeatureProvider(dictionary: ["audio": audio, "lstm": lstm])
        let out = try model.prediction(from: input)
        guard let prob = out.featureValue(for: "prob")?.multiArrayValue,
              let next = out.featureValue(for: "lstmOut")?.multiArrayValue else {
            throw AudioIOError.unreadable("SileroVAD output")
        }
        copy(next, into: lstm)
        return prob[0].floatValue
    }

    private func fill(_ array: MLMultiArray, with value: Float) {
        array.dataPointer.assumingMemoryBound(to: Float.self).update(repeating: value, count: array.count)
    }

    /// 出力の配列は行の幅が詰まっていないことがあるので、strideを見て写す
    private func copy(_ src: MLMultiArray, into dst: MLMultiArray) {
        let d = dst.dataPointer.assumingMemoryBound(to: Float.self)
        let rowStride = src.strides[0].intValue
        let colStride = src.strides[2].intValue
        src.withUnsafeBufferPointer(ofType: Float.self) { s in
            for row in 0..<2 {
                for col in 0..<128 {
                    d[row * 128 + col] = s[row * rowStride + col * colStride]
                }
            }
        }
    }
}

struct VADState: Codable, Equatable {
    var context: [Float]
    var lstm: [Float]
}
