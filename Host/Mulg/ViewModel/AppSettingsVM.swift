//
//  AppSettingsVM.swift
//  Mulg
//
//  Created by 이승윤 on 2022/08/15.
//

import Foundation

class AppSettingsVM: ObservableObject {
    let app: MulgGame
    @Published var settings: AppSettings

    init(app: MulgGame) {
        self.app = app
        settings = app.settings
    }
}
