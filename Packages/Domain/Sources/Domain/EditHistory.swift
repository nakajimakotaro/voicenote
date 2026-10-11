import Foundation

/// 取り消しとやり直しの履歴。`Edit` は変更前と変更後を両方持つ値にし、どちらに戻すかは呼び出し側が決める
public struct EditHistory<Edit>: Sendable where Edit: Sendable {
    private var undoStack: [Edit] = []
    private var redoStack: [Edit] = []

    public init() {}

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    /// 新しい操作を積む。やり直しの履歴は消える
    public mutating func record(_ edit: Edit) {
        undoStack.append(edit)
        redoStack.removeAll()
    }

    /// 取り消す操作を返す。呼び出し側は変更前の状態に戻す
    public mutating func undo() -> Edit? {
        guard let edit = undoStack.popLast() else { return nil }
        redoStack.append(edit)
        return edit
    }

    /// やり直す操作を返す。呼び出し側は変更後の状態にする
    public mutating func redo() -> Edit? {
        guard let edit = redoStack.popLast() else { return nil }
        undoStack.append(edit)
        return edit
    }
}
