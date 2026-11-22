/// Cursor access for games retaining their own mouse/keyboard implementation.
/// Independent of the mapped camera state and any other gameplay keys/buttons.
struct NativeCursorMode: Equatable {
    private(set) var released = false
    private var cursorKeysHeld: Set<UInt16> = []
    private var tapPending = false
    private var middleHeld = false

    init(released: Bool = false) { self.released = released }

    mutating func modifier(code: UInt16, pressed: Bool, cursorKeys: Set<UInt16>, commandDown: Bool) -> Bool {
        if commandDown { tapPending = false }
        guard cursorKeys.contains(code) else { return false }
        if pressed {
            if cursorKeysHeld.isEmpty { tapPending = !commandDown }
            cursorKeysHeld.insert(code)
            return false
        }
        guard cursorKeysHeld.remove(code) != nil, cursorKeysHeld.isEmpty, tapPending else { return false }
        tapPending = false
        released.toggle()
        return true
    }

    mutating func mouse(button: Int, pressed: Bool) -> Bool {
        guard button == 2 else { return false }
        tapPending = false
        if !pressed { middleHeld = false; return false }
        guard !middleHeld else { return false }
        middleHeld = true
        released.toggle()
        return true
    }

    mutating func focusLost() {
        cursorKeysHeld.removeAll()
        tapPending = false
        middleHeld = false
    }
}
