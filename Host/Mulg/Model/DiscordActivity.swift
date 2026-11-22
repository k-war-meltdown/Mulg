//
//  DiscordActivity.swift
//  Mulg
//
//  Created by 이승윤 on 2022/07/16.
//

import Foundation

// Value edits must pass through AppSettings.settings.didSet so GUI changes are persisted.
struct DiscordActivity: Codable, Sendable {
    var enable = true
    var applicationID = ""
    var details = ""
    var state = ""
    var image = ""
}
