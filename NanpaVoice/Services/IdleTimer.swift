import UIKit

/// 画面の自動ロックを止める。解析と文字起こしのどちらかが動いている間は止めたままにする
/// （裏に回ると処理が止まるため）
@MainActor
enum IdleTimer {
    enum Reason: Hashable {
        case analysis
        case transcription
    }

    private static var active: Set<Reason> = []

    static func set(_ reason: Reason, active isActive: Bool) {
        if isActive { active.insert(reason) } else { active.remove(reason) }
        UIApplication.shared.isIdleTimerDisabled = !active.isEmpty
    }
}
