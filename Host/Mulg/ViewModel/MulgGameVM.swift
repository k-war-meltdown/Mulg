//
//  MulgGameVM.swift
//  Mulg
//
//  Created by Adam Chen JingFan on 4/7/24.
//

import SwiftUI

class MulgGameVM: ObservableObject {
    @Published var app: MulgGame
    @Published var showSettings = false
    @Published var showClearPreferencesAlert = false
    @Published var showClearMulgChainAlert = false
    @Published var showStartingProgress = false
    @Published var showImportSuccess = false
    @Published var showImportFail = false
    @Published var showKeymapSheet = false

    init(app: MulgGame) {
        self.app = app
    }
}
