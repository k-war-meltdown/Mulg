//
//  MulgRules.swift
//  Mulg
//
//  Created by lucus lee on 2022/07/10.
//

import Foundation

struct MulgRules: Decodable {
    var blocklist: [String]?
    var greenlist: [String]?
    var allow: [String]?
    var bypass: [String]?

    // The bundled default.yaml and users' own rule files use upstream's names (blacklist, whitelist). The
    // renamed properties once decoded only the new names, so every deny entry was silently dropped.
    enum CodingKeys: String, CodingKey {
        case blocklist, greenlist, allow, bypass, blacklist, whitelist
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let blocked = try container.decodeIfPresent([String].self, forKey: .blocklist)
        let legacyBlocked = try container.decodeIfPresent([String].self, forKey: .blacklist)
        let green = try container.decodeIfPresent([String].self, forKey: .greenlist)
        let legacyGreen = try container.decodeIfPresent([String].self, forKey: .whitelist)
        blocklist = blocked == nil && legacyBlocked == nil ? nil : (blocked ?? []) + (legacyBlocked ?? [])
        greenlist = green == nil && legacyGreen == nil ? nil : (green ?? []) + (legacyGreen ?? [])
        allow = try container.decodeIfPresent([String].self, forKey: .allow)
        bypass = try container.decodeIfPresent([String].self, forKey: .bypass)
    }

    public static func buildRules(rules: [String], bundleID: String) -> [String] {
        let homeDirectory = FileManager.default.homeDirectoryForCurrentUser
        var result: [String] = []
        let template = RuleTemplate(data: [
            "BundleID": bundleID,
            "HomeDirectory": homeDirectory.path
        ])
        for rule in rules {
            result.append(template.render(template: rule))
        }
        return result
    }
}

@dynamicMemberLookup
struct RuleTemplate {
    private var data: [String: String]

    init(data: [String: String] = [:]) {
        self.data = data
    }

    func render(template: String) -> String {
        data.reduce(template) { $0.replacingOccurrences(of: "${\($1.key)}", with: $1.value) }
    }

    subscript(dynamicMember member: String) -> CustomStringConvertible? {
        get { data[member] }
        set { data[member] = newValue?.description }
    }

    subscript(dynamicMember member: String) -> Date {
        get { dateFormatter.date(from: data[member] ?? "") ?? Date(timeIntervalSince1970: 0) }
        set { data[member] = dateFormatter.string(from: newValue) }
    }

    let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZZZZZ"
        formatter.calendar = Calendar(identifier: .gregorian)
        return formatter
    }()
}
