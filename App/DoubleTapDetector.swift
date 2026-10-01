import Foundation

/// 左 Shift のダブルタップの判定。キーの並びだけを受け取る（ユニットテストする）。
/// 「押す→離す」を 2 回。しきい値は 2 つ:
/// - maxPressDuration: 1 回の押しの長さ（これより長い押しはタップではない）
/// - maxGap: 1 回目に離してから 2 回目に押すまで
/// 間に他のキー・他の修飾キーが入ったら取り消す（大文字を打つときの Shift で誤発火させない）
struct DoubleTapDetector {
    enum Input: Equatable {
        case leftShiftDown(TimeInterval)
        case leftShiftUp(TimeInterval)
        case other
    }

    var maxPressDuration: TimeInterval = 0.3
    var maxGap: TimeInterval = 0.3

    private enum State {
        case idle
        case firstDown(TimeInterval)
        case firstUp(TimeInterval)
        case secondDown(TimeInterval)
    }

    private var state: State = .idle

    /// ダブルタップが成立したら true（2 回目に離したとき）
    mutating func handle(_ input: Input) -> Bool {
        switch (state, input) {
        case (_, .other):
            state = .idle
        case (.firstDown(let t0), .leftShiftUp(let t)):
            state = t - t0 <= maxPressDuration ? .firstUp(t) : .idle
        case (.firstUp(let t0), .leftShiftDown(let t)):
            state = t - t0 <= maxGap ? .secondDown(t) : .firstDown(t)
        case (.secondDown(let t0), .leftShiftUp(let t)):
            state = .idle
            return t - t0 <= maxPressDuration
        case (_, .leftShiftDown(let t)):
            state = .firstDown(t)
        case (_, .leftShiftUp):
            state = .idle
        }
        return false
    }
}

/// NSEvent の中身（種類・keyCode・修飾キーのフラグ）を判定の入力に直す
enum ShiftTapMapping {
    static let leftShiftKeyCode: UInt16 = 56
    /// デバイスごとの修飾キーのフラグ（NX_DEVICELSHIFTKEYMASK / NX_DEVICERSHIFTKEYMASK）
    static let deviceLeftShift: UInt = 0x2
    static let deviceRightShift: UInt = 0x4
    /// Command・Option・Control・Fn（NSEvent.ModifierFlags と同じ値）
    static let otherModifiers: UInt = (1 << 20) | (1 << 19) | (1 << 18) | (1 << 23)

    enum Kind { case keyDown, flagsChanged }

    static func input(kind: Kind, keyCode: UInt16, modifierFlags: UInt, timestamp: TimeInterval) -> DoubleTapDetector.Input {
        guard kind == .flagsChanged, keyCode == leftShiftKeyCode else { return .other }
        // 左 Shift と一緒に他の修飾キーや右 Shift が押されているなら、ただのタップではない
        if modifierFlags & otherModifiers != 0 || modifierFlags & deviceRightShift != 0 { return .other }
        return modifierFlags & deviceLeftShift != 0 ? .leftShiftDown(timestamp) : .leftShiftUp(timestamp)
    }
}
