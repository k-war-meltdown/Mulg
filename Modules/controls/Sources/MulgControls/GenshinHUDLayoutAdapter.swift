import CoreGraphics
import MulgContracts
import MulgControlLayout

/// The generic solver does not know what a party is. This adapter recognizes only
/// Genshin's existing ordered numeric touch column, and measures visible HUD rows.
enum GenshinHUDLayoutAdapter {
    static func discover(in image: HUDGrayImage, map: KeymappingData, group: HUDLayoutGroup,
                         targets: [HUDControlTarget], aspect: Double) -> (points: [HUDLayoutPoint], confidence: Double, regime: String)? {
        guard GenshinDefaults.applies(to: map.bundleIdentifier), group.axis == .column,
              group.horizontalAnchor == .right, group.members.count == 4,
              group.members.allSatisfy({ $0.layer == 0 && $0.kind == .button }),
              group.members.allSatisfy({ map.buttonModels.indices.contains($0.index) }),
              group.members.map({ map.buttonModels[$0.index].keyCode }) == [30, 31, 32, 33],
              !map.validHUDAnchors.contains(where: { group.members.contains($0.address) }),
              group.members.allSatisfy({ address in
                  !(map.buttonModels[address.index].transform.hudSamples ?? []).contains { $0.source == .calibrated }
              }) else { return nil }
        let members = group.members.compactMap { address in targets.first { $0.address == address } }
        guard members.count == 4, aspect.isFinite, aspect > 0 else { return nil }
        let xs = members.map { Double($0.transform.xCoord) }, ys = members.map { Double($0.transform.yCoord) }
        let x = xs.reduce(0, +) / 4
        let gaps = zip(ys, ys.dropFirst()).map { $0.1 - $0.0 }
        let gap = gaps.reduce(0, +) / 3
        // Text occupies the region beside the portrait; exclude the portrait's white hair
        // and the separate burst icon. The captured row is later matched as its own patch.
        let left = max(0.55, x - 0.2 / aspect), right = min(0.94, x + 0.04 / aspect)
        let region = CGRect(x: left, y: max(0.12, ys.min()! - 0.12), width: right - left,
                            height: min(0.75, ys.max()! + 0.24) - max(0.12, ys.min()! - 0.12))
        guard let rows = HUDRepeatedRowDiscovery.find(in: image, region: region,
            expectedGap: gap, allowedCounts: [3, 4]) else { return nil }
        let points = group.members.enumerated().map { index, address in
            HUDLayoutPoint(address: address, point: CGPoint(x: x,
                y: index < rows.centers.count ? rows.centers[index] : rows.centers.last!),
                available: index < rows.centers.count)
        }
        guard HUDGroupSearch.coherent(points, group: group, aspect: aspect) else { return nil }
        return (points, rows.confidence, "genshin-visible-rows-\(rows.centers.count)")
    }
}
