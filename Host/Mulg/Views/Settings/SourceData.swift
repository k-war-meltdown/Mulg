//
//  SourceData.swift
//  Mulg
//
//  IPA source records, kept for StoreVM (app update checks). The IPA Library screens and the
//  sources settings tab were removed on 2026-10-05; these types are all that remains of them.
//

import Foundation

struct SourceData: Identifiable, Hashable {
    var id: UUID
    var source: String
    var status: SourceValidation
    var isEnabled: Bool

}

extension SourceData: Codable {
    init(source: String, isEnabled: Bool) {
        self.id = UUID()
        self.source = source
        self.status = .checking
        self.isEnabled = isEnabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(),
            source: try container.decode(String.self, forKey: .source),
            status: .checking,
            isEnabled: try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        )
    }
}

enum SourceValidation: Codable {
    case badjson, badurl, checking, duplicate, valid, empty
}
