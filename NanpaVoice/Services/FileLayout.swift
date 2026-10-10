import AudioIO
import Foundation

/// 端末上のファイル配置。パスの組み立てはここだけで行う
///
///     App Groupのコンテナ/Inbox/   Share Extensionが受け取ったファイル（AppGroup.inboxDir）
///     Application Support/recordings/{recordingId}/
///       source.{ext}  regions.jsonl  checkpoint.json  peaks_50.bin  peaks_1.bin
///     tmp/            送信用・書き出し用の一時mp3
enum FileLayout {
    static var recordingsDir: URL {
        URL.applicationSupportDirectory.appendingPathComponent("recordings", isDirectory: true)
    }

    static func recordingDir(_ id: UUID) -> URL {
        recordingsDir.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    static func source(_ id: UUID, ext: String) -> URL {
        recordingDir(id).appendingPathComponent("source.\(ext)")
    }

    static func source(_ id: UUID, fileName: String) -> URL {
        recordingDir(id).appendingPathComponent(fileName)
    }

    static func regions(_ id: UUID) -> URL { recordingDir(id).appendingPathComponent("regions.jsonl") }
    static func checkpoint(_ id: UUID) -> URL { recordingDir(id).appendingPathComponent("checkpoint.json") }
    static func peaks50(_ id: UUID) -> URL { recordingDir(id).appendingPathComponent("peaks_50.bin") }
    static func peaks1(_ id: UUID) -> URL { recordingDir(id).appendingPathComponent("peaks_1.bin") }

    static func analysisFiles(_ id: UUID) -> AnalysisFiles {
        AnalysisFiles(regions: regions(id), checkpoint: checkpoint(id), peaks50: peaks50(id), peaks1: peaks1(id))
    }

    static var tmpDir: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("work", isDirectory: true)
    }

    static func ensureDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    /// 録音に関係するファイルをすべて消す
    static func removeRecordingFiles(_ id: UUID) throws {
        let dir = recordingDir(id)
        if FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.removeItem(at: dir)
        }
    }

    /// 一時フォルダを空にする（起動時と書き出し前に呼ぶ）
    static func cleanTmp() {
        try? FileManager.default.removeItem(at: tmpDir)
        try? ensureDirectory(tmpDir)
    }
}
