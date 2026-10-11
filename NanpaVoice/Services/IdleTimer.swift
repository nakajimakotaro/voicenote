import UIKit

/// 画面の自動ロックを止める。解析、文字起こし、書き出しのどれかが動いている間は止めたままにする
/// （裏に回ると処理が止まるため）。Mac ではスリープと App Nap を止める
@MainActor
enum IdleTimer {
    enum Reason: Hashable {
        case analysis
        case transcription
        case export
    }

    private static var active: Set<Reason> = []
    #if targetEnvironment(macCatalyst)
    private static var activity: NSObjectProtocol?
    #endif

    static func set(_ reason: Reason, active isActive: Bool) {
        if isActive { active.insert(reason) } else { active.remove(reason) }
        #if targetEnvironment(macCatalyst)
        if active.isEmpty, let current = activity {
            ProcessInfo.processInfo.endActivity(current)
            activity = nil
        } else if !active.isEmpty, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .idleSystemSleepDisabled], reason: "音声の処理中")
        }
        #else
        UIApplication.shared.isIdleTimerDisabled = !active.isEmpty
        #endif
    }
}
