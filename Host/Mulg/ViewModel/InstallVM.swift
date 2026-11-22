//
//  InstallVM.swift
//  Mulg
//

import Foundation

enum InstallStepsNative: String {
    case unzip = "mulggame.install.unzip",
         wrapper = "mulggame.install.createWrapper",
         mulgkit = "mulggame.install.installMulgKit",
         sign = "mulggame.install.signing",
         library = "mulggame.install.addToLib",
         begin = "mulggame.install.copy",
         finish = "mulggame.progress.finished",
         failed = "mulggame.progress.failed"
}

class InstallVM: ProgressVM<InstallStepsNative> {

    static let shared = InstallVM()

    init() {
        super.init(start: .begin, ends: [.finish, .failed])
    }

}
