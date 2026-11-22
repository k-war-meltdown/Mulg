//
//  DownloadVM.swift
//  Mulg
//
//  Created by Isaac Marovitz on 01/10/2022.
//

import Foundation

enum DownloadStepsNative: String {
    case downloading = "mulggame.download.downloading",
         integrity = "mulggame.download.integrityCheck",
         finish = "mulggame.progress.finished",
         failed = "mulggame.progress.failed",
         canceled = "mulggame.progress.canceled"
}

class DownloadVM: ProgressVM<DownloadStepsNative> {
    @Published var storeAppData: SourceAppsData?

    static let shared = DownloadVM()

    init() {
        super.init(start: .downloading, ends: [.finish, .failed, .canceled])
    }

}
