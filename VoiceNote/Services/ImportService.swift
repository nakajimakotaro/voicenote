import AudioIO
import Foundation
import SwiftData

/// 音声ファイルをアプリ領域に取り込み、Recordingを作る。元のファイルは書き換えない
@MainActor
struct ImportService {
    static let supportedExtensions: Set<String> = ["m4a", "aac", "mp3", "wav"]

    enum ImportError: LocalizedError {
        case unsupported(String)
        case unreadable(String)

        var errorDescription: String? {
            switch self {
            case .unsupported(let name): "\(name) は対応していない形式です（m4a / aac / mp3 / wav）"
            case .unreadable(let name): "\(name) を音声として読み込めませんでした"
            }
        }
    }

    let context: ModelContext

    /// ファイル選択で選んだファイルをコピーして取り込む
    func importPicked(_ url: URL) async throws -> Recording {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        return try await importFile(at: url, move: false)
    }

    /// Share Extensionが Inbox に置いたファイルをすべて取り込む。失敗したものは捨ててエラーを返す
    func importInbox() async -> (imported: [Recording], errors: [Error]) {
        guard let inbox = AppGroup.inboxDir,
              let items = try? FileManager.default.contentsOfDirectory(
                  at: inbox, includingPropertiesForKeys: [.creationDateKey], options: .skipsHiddenFiles)
        else { return ([], []) }

        var imported: [Recording] = []
        var errors: [Error] = []
        let sorted = items.sorted { creationDate($0) < creationDate($1) }
        for item in sorted {
            let files = (try? FileManager.default.contentsOfDirectory(
                at: item, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
            for file in files {
                do {
                    imported.append(try await importFile(at: file, move: true))
                } catch {
                    errors.append(error)
                }
            }
            try? FileManager.default.removeItem(at: item)
        }
        return (imported, errors)
    }

    private func importFile(at url: URL, move: Bool) async throws -> Recording {
        let name = url.lastPathComponent
        let ext = url.pathExtension.lowercased()
        guard Self.supportedExtensions.contains(ext) else { throw ImportError.unsupported(name) }
        let modifiedAt = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate

        let id = UUID()
        let dest = FileLayout.source(id, ext: ext)
        // 数百MBになることがあるので、コピーはメインスレッドの外で行う
        try await Task.detached {
            try FileLayout.ensureDirectory(FileLayout.recordingDir(id))
            if move {
                try FileManager.default.moveItem(at: url, to: dest)
            } else {
                try FileManager.default.copyItem(at: url, to: dest)
            }
        }.value

        let info: AudioInfo
        do {
            info = try await audioInfo(of: dest)
        } catch {
            try? FileLayout.removeRecordingFiles(id)
            throw ImportError.unreadable(name)
        }

        let recording = Recording(
            id: id,
            name: url.deletingPathExtension().lastPathComponent,
            sourceFileName: dest.lastPathComponent,
            durationMs: info.durationMs,
            createdAt: info.recordedAt ?? modifiedAt ?? .now
        )
        context.insert(recording)
        try context.save()
        return recording
    }

    private func creationDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
    }
}
