import Foundation
import MulgEngine

extension NoticeCenter {
    /// Camera reach notices are progress the player started and is waiting on, so they show even
    /// while notices are hidden (a full-screen game in performance mode). Build 897 hid them all:
    /// calibration looked dead, the player pressed the key again, and that cancelled it.
    func showImportant(_ notice: Notice) {
        show(Notice(notice.title, lines: notice.lines, style: notice.style, duration: notice.duration, important: true))
    }
}
