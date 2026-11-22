import CoreGraphics
import MulgContracts

/// Numeric HUD positions from PlayCover/keymaps' Genshin Impact fixed 16by9,
/// fixed 16by10 and Genshin_Impact_for_21_by_9_Ultrawide community profiles.
/// https://github.com/PlayCover/keymaps/tree/master/keymapping/com.miHoYo.GenshinImpact
/// They describe the touchscreen HUD, not a controller layout. Bindings remain the
/// player's existing bindings; only a recognized unedited source layout gains samples.
enum GenshinHUDLayouts {
    private struct Point {
        let aspect: Double
        let x: CGFloat
        let y: CGFloat
    }
    private static let buttons: [Int: [Point]] = [
        -2: [
            Point(aspect: 1.7777777777777777, x: 0.922054041756524, y: 0.86262201944987),
            Point(aspect: 1.6, x: 0.9218397352430555, y: 0.8750303819444445),
            Point(aspect: 2.3333333333333335, x: 0.8719442047197997, y: 0.8564729817708334),
        ],
        -1: [
            Point(aspect: 1.7777777777777777, x: 0.826386178864373, y: 0.7675863280119718),
            Point(aspect: 1.6, x: 0.8266248914930555, y: 0.7892925347222223),
            Point(aspect: 2.3333333333333335, x: 0.8018962850250322, y: 0.7697721354166668),
        ],
        5: [
            Point(aspect: 1.7777777777777777, x: 0.8934651692708333, y: 0.05085503472222222),
            Point(aspect: 1.6, x: 0.8934651692708333, y: 0.05085503472222222),
            Point(aspect: 2.3333333333333335, x: 0.8871913229772287, y: 0.051983506944444445),
        ],
        6: [
            Point(aspect: 1.7777777777777777, x: 0.9537462022569444, y: 0.04967447916666665),
            Point(aspect: 1.6, x: 0.9537462022569444, y: 0.04967447916666665),
            Point(aspect: 2.3333333333333335, x: 0.9361487731145025, y: 0.05644531249999999),
        ],
        8: [
            Point(aspect: 1.7777777777777777, x: 0.7311740451388888, y: 0.8599734807897497),
            Point(aspect: 1.6, x: 0.7311740451388888, y: 0.8751258680555556),
            Point(aspect: 2.3333333333333335, x: 0.7311740451388888, y: 0.8751258680555556),
        ],
        9: [
            Point(aspect: 1.7777777777777777, x: 0.6330891977544144, y: 0.5001479215773467),
            Point(aspect: 1.6, x: 0.6336887012715653, y: 0.5284272331459952),
            Point(aspect: 2.3333333333333335, x: 0.636025638044821, y: 0.5023123242918281),
        ],
        10: [
            Point(aspect: 1.7777777777777777, x: 0.6337782091564607, y: 0.4143798178213614),
            Point(aspect: 1.6, x: 0.6328559027777783, y: 0.45543402777777775),
            Point(aspect: 2.3333333333333335, x: 0.6359207192748713, y: 0.38817871093749995),
        ],
        11: [
            Point(aspect: 1.7777777777777777, x: 0.7168488286075615, y: 0.5036154795879851),
            Point(aspect: 1.6, x: 0.7168488286075615, y: 0.5036154795879851),
            Point(aspect: 2.3333333333333335, x: 0.7036459307151196, y: 0.4441970768102075),
        ],
        12: [
            Point(aspect: 1.7777777777777777, x: 0.7157443629370797, y: 0.0548852284749349),
            Point(aspect: 1.6, x: 0.7155056423611111, y: 0.051909722222222225),
            Point(aspect: 2.3333333333333335, x: 0.751304606750646, y: 0.05527615017361111),
        ],
        13: [
            Point(aspect: 1.7777777777777777, x: 0.03744846185048424, y: 0.23979890046296298),
            Point(aspect: 1.6, x: 0.03942871093750003, y: 0.2096918402777778),
            Point(aspect: 2.3333333333333335, x: 0.06308877634447677, y: 0.23451822916666668),
        ],
        15: [
            Point(aspect: 1.7777777777777777, x: 0.06499565442403162, y: 0.49865548310456465),
            Point(aspect: 1.6, x: 0.0653483072916667, y: 0.5480815972222224),
            Point(aspect: 2.3333333333333335, x: 0.0653483072916667, y: 0.5480815972222224),
        ],
        16: [
            Point(aspect: 1.7777777777777777, x: 0.10757921006944444, y: 0.14312547754358373),
            Point(aspect: 1.6, x: 0.10934516059027778, y: 0.12601996527777787),
            Point(aspect: 2.3333333333333335, x: 0.11718037134609173, y: 0.1534857855902779),
        ],
        17: [
            Point(aspect: 1.7777777777777777, x: 0.021302628517150875, y: 0.1395264180501302),
            Point(aspect: 1.6, x: 0.02584635416666666, y: 0.12885416666666663),
            Point(aspect: 2.3333333333333335, x: 0.04748970445736432, y: 0.15255208333333342),
        ],
        18: [
            Point(aspect: 1.7777777777777777, x: 0.7755018419689602, y: 0.05727672153049046),
            Point(aspect: 1.6, x: 0.7754909939236111, y: 0.049830729166666664),
            Point(aspect: 2.3333333333333335, x: 0.7946679561329134, y: 0.056037326388888885),
        ],
        19: [
            Point(aspect: 1.7777777777777777, x: 0.8314941432740953, y: 0.05292824074074075),
            Point(aspect: 1.6, x: 0.8355333116319444, y: 0.04986111111111111),
            Point(aspect: 2.3333333333333335, x: 0.8419343381581071, y: 0.054372287326388886),
        ],
        20: [
            Point(aspect: 1.7777777777777777, x: 0.6441770153082889, y: 0.9003160575542759),
            Point(aspect: 1.6, x: 0.6439708468156538, y: 0.9103420992209424),
            Point(aspect: 2.3333333333333335, x: 0.6612582741412352, y: 0.9006497164084425),
        ],
        21: [
            Point(aspect: 1.7777777777777777, x: 0.6972710582945084, y: 0.7460064669008609),
            Point(aspect: 1.6, x: 0.6974500868055559, y: 0.7716189236111111),
            Point(aspect: 2.3333333333333335, x: 0.6919654392764861, y: 0.7412885199652777),
        ],
        23: [
            Point(aspect: 1.7777777777777777, x: 0.7573920355902778, y: 0.6742144097222222),
            Point(aspect: 1.6, x: 0.7573920355902778, y: 0.6742144097222222),
            Point(aspect: 2.3333333333333335, x: 0.7461047899507429, y: 0.6525726996527776),
        ],
        24: [
            Point(aspect: 1.7777777777777777, x: 0.6560438368055554, y: 0.053789062500000026),
            Point(aspect: 1.6, x: 0.6560438368055554, y: 0.053789062500000026),
            Point(aspect: 2.3333333333333335, x: 0.7080991602067183, y: 0.056010742187500025),
        ],
        25: [
            Point(aspect: 1.7777777777777777, x: 0.09708658854166667, y: 0.2976794122766565),
            Point(aspect: 1.6, x: 0.1029541015625, y: 0.2846875),
            Point(aspect: 2.3333333333333335, x: 0.08769815134447674, y: 0.31556857638888935),
        ],
        27: [
            Point(aspect: 1.7777777777777777, x: 0.8263671875, y: 0.7657031250000002),
            Point(aspect: 1.6, x: 0.826708984375, y: 0.7898350694444445),
            Point(aspect: 2.3333333333333335, x: 0.7967262445494186, y: 0.7648947482638888),
        ],
        28: [
            Point(aspect: 1.7777777777777777, x: 0.23742421100215638, y: 0.0527784915201372),
            Point(aspect: 1.6, x: 0.23725331256465637, y: 0.049730647304461584),
            Point(aspect: 2.3333333333333335, x: 0.21202506946872615, y: 0.04997207525585047),
        ],
        29: [
            Point(aspect: 1.7777777777777777, x: 0.32575777946535484, y: 0.9004477869384129),
            Point(aspect: 1.6, x: 0.3256926752986882, y: 0.9101024890190337),
            Point(aspect: 2.3333333333333335, x: 0.36043104739171145, y: 0.916528812803756),
        ],
        30: [
            Point(aspect: 1.7777777777777777, x: 0.9001410643259684, y: 0.21119262130172162),
            Point(aspect: 1.6, x: 0.8950602213541666, y: 0.2949262152777778),
            Point(aspect: 2.3333333333333335, x: 0.8819779628205009, y: 0.214982406374008),
        ],
        31: [
            Point(aspect: 1.7777777777777777, x: 0.9005099773406983, y: 0.3211414930555556),
            Point(aspect: 1.6, x: 0.89765625, y: 0.3927994791666667),
            Point(aspect: 2.3333333333333335, x: 0.8788347989881818, y: 0.3251701421586296),
        ],
        32: [
            Point(aspect: 1.7777777777777777, x: 0.9002902560763888, y: 0.4345032699019819),
            Point(aspect: 1.6, x: 0.8997205946180555, y: 0.48443576388888887),
            Point(aspect: 2.3333333333333335, x: 0.881964480828517, y: 0.42899525152943113),
        ],
        33: [
            Point(aspect: 1.7777777777777777, x: 0.9038408413347587, y: 0.5374442789708574),
            Point(aspect: 1.6, x: 0.8981171026644096, y: 0.5629843977181446),
            Point(aspect: 2.3333333333333335, x: 0.8867822793432751, y: 0.5399628633080413),
        ],
        40: [
            Point(aspect: 1.7777777777777777, x: 0.041300296364556656, y: 0.9176781824344759),
            Point(aspect: 1.6, x: 0.040348147927056655, y: 0.9264359079028642),
            Point(aspect: 2.3333333333333335, x: 0.06112735395903335, y: 0.9195619929723088),
        ],
        41: [
            Point(aspect: 1.7777777777777777, x: 0.031811518139309304, y: 0.057786458333333325),
            Point(aspect: 1.6, x: 0.034849717881944395, y: 0.04671874999999998),
            Point(aspect: 2.3333333333333335, x: 0.061617750222060674, y: 0.054102647569444426),
        ],
        43: [
            Point(aspect: 1.7777777777777777, x: 0.18076442612542049, y: 0.05199749699345346),
            Point(aspect: 1.6, x: 0.18101128472222222, y: 0.04226562500000005),
            Point(aspect: 2.3333333333333335, x: 0.1692527908995478, y: 0.04819010416666671),
        ],
        44: [
            Point(aspect: 1.7777777777777777, x: 0.9210367785559761, y: 0.656048900462963),
            Point(aspect: 1.6, x: 0.9219021267361112, y: 0.6900477430555556),
            Point(aspect: 2.3333333333333335, x: 0.869138227753553, y: 0.6594867621527776),
        ],
        224: [
            Point(aspect: 1.7777777777777777, x: 0.9761149088541666, y: 0.9496310763888889),
            Point(aspect: 1.6, x: 0.9761149088541666, y: 0.9561414930555555),
            Point(aspect: 2.3333333333333335, x: 0.926703117429748, y: 0.9538628472222223),
        ],
        225: [
            Point(aspect: 1.7777777777777777, x: 0.9223063151041667, y: 0.8627401620370371),
            Point(aspect: 1.6, x: 0.9223063151041667, y: 0.8748350694444444),
            Point(aspect: 2.3333333333333335, x: 0.8722892820373063, y: 0.8573708767361111),
        ],
    ]

    private static let sticks: [Int: [Point]] = [
        26: [
            Point(aspect: 1.7777777777777777, x: 0.15571998992896346, y: 0.7634631988920904),
            Point(aspect: 1.6, x: 0.15592072247799502, y: 0.787209322029388),
            Point(aspect: 2.3333333333333335, x: 0.18029731223090203, y: 0.7296056978974448),
        ],
        82: [
            Point(aspect: 1.7777777777777777, x: 0.15598155177050263, y: 0.49724685261791407),
            Point(aspect: 1.6, x: 0.15598155177050263, y: 0.49724685261791407),
            Point(aspect: 2.3333333333333335, x: 0.16535655177050265, y: 0.4972414272706918),
        ],
    ]

    static func adaptingKnownLayout(_ original: KeymappingData) -> KeymappingData {
        guard let aspect = original.mulgAspectRatio, aspect.isFinite, aspect > 0,
              let movement = original.joystickModel.first(where: { $0.upKeyCode == 26 && !$0.isAnalog }),
              let attack = original.buttonModels.first(where: { $0.keyCode == -1 }),
              !movement.transform.hasObservedHUDSamples, !attack.transform.hasObservedHUDSamples,
              abs(movement.transform.yCoord - 0.7634631988920904) < 0.002,
              abs(movement.transform.xCoord * CGFloat(aspect) - 0.1557199899289635 * CGFloat(16.0 / 9)) < 0.004,
              abs(attack.transform.yCoord - 0.7675863280119718) < 0.002,
              abs((1 - attack.transform.xCoord) * CGFloat(aspect) - (1 - 0.826386178864373) * CGFloat(16.0 / 9)) < 0.004
        else { return original }

        // Earlier M5 profiles converted X/size to 4:3 but kept the 16:9 Y positions.
        // Restore the actual source reference before using measured layout samples.
        var map = original.fitted(toWidth: 16, height: 9)
        map.mulgLockAspectRatio = false
        let aliases = [58: 19, 59: 28, 60: 18, 61: 12, 62: 24, -3: 43]
        func sampled(_ transform: KeyModelTransform, original: KeyModelTransform, points: [Point]?) -> KeyModelTransform {
            guard !transform.hasObservedHUDSamples, let points,
                  let reference = points.first(where: { abs($0.aspect - 16.0 / 9) < 0.001 }),
                  abs(original.yCoord - reference.y) < 0.002 else { return transform }
            // Old rebasing omitted inferred anchors. A right-attached shortcut could then
            // be inferred as centered after converting to 4:3. Match the original source
            // through each possible legacy anchor, not through that later wrong inference.
            let stockX = [CGFloat(0), 0.5, 1].contains { anchor in
                let expected = anchor + (reference.x - anchor) * CGFloat(reference.aspect / aspect)
                return abs(original.xCoord - expected) < 0.002
            }
            guard stockX else { return transform } // Preserve user-adjusted targets.
            var result = transform
            result.xCoord = reference.x
            result.yCoord = reference.y
            let source = KeyModelTransform(size: transform.size, xCoord: reference.x, yCoord: reference.y,
                horizontalAnchor: original.horizontalAnchor, verticalAnchor: original.verticalAnchor)
                .fitted(from: reference.aspect, to: reference.aspect)
            result.horizontalAnchor = source.horizontalAnchor
            result.verticalAnchor = source.verticalAnchor
            result.hudSamples = points.map { point in
                let canvas = KeymapCanvas(referenceAspectRatio: 16.0 / 9, viewportAspectRatio: point.aspect)!
                let size = transform.size * CGFloat((16.0 / 9) / max(1, point.aspect)) * canvas.scaleInHeights
                return ControlHUDSample(aspectRatio: point.aspect, xCoord: point.x, yCoord: point.y, size: size, source: .published)
            }
            return result
        }
        for i in map.buttonModels.indices {
            let code = map.buttonModels[i].keyCode
            map.buttonModels[i].transform = sampled(map.buttonModels[i].transform,
                original: original.buttonModels[i].transform, points: buttons[aliases[code] ?? code])
        }
        for i in map.draggableButtonModels.indices {
            let code = map.draggableButtonModels[i].keyCode
            map.draggableButtonModels[i].transform = sampled(map.draggableButtonModels[i].transform,
                original: original.draggableButtonModels[i].transform, points: buttons[aliases[code] ?? code])
        }
        for i in map.joystickModel.indices {
            let code = map.joystickModel[i].upKeyCode
            map.joystickModel[i].transform = sampled(map.joystickModel[i].transform,
                original: original.joystickModel[i].transform, points: sticks[code])
        }
        return map
    }
}
