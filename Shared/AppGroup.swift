import Foundation

/// アプリ本体とShare Extensionで共有するフォルダ
enum AppGroup {
    static let identifier = "group.jp.haru.VoiceNote"

    /// Share Extensionが受け取ったファイルを置く。1件ごとに `Inbox/{uuid}/{元のファイル名}`。
    /// 書き込み中のものは `.` で始まる名前にしておき、書き終えたら名前を変える
    static var inboxDir: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)?
            .appendingPathComponent("Inbox", isDirectory: true)
    }
}
