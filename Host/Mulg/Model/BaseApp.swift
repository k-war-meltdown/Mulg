//
//  BaseApp.swift
//  Mulg
//

import Foundation

public class BaseApp: @unchecked Sendable {
    /// All mach-o binaries within the app, including the executable itself.
    /// Call resolveValidMachOs to ensure a non-nil value.
    public var validMachOs: [URL]?

    public let info: AppInfo
    public var url: URL

    public var executable: URL {
        url.appendingEscapedPathComponent(info.executableName)
    }

    public var entitlements: URL {
        let embedded = url.appendingPathComponent(Self.originalEntitlementsFileName)
        if FileManager.default.fileExists(atPath: embedded.path) { return embedded }
        return legacyEntitlements
    }

    public static let originalEntitlementsFileName = "MulgOriginalEntitlements.plist"
    public var legacyEntitlements: URL {
        Entitlements.mulgEntitlementsDir
            .appendingPathComponent(info.bundleIdentifier)
            .appendingPathExtension("plist")
    }

    init(appUrl: URL) {
        url = appUrl
        info = AppInfo(contentsOf: url.appendingPathComponent("Info")
                                      .appendingPathExtension("plist"))
    }
}
