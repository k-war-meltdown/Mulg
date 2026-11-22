//
//  KeymapData.swift
//  Mulg
//
//  Created by Isaac Marovitz on 23/08/2022.
//

import MulgContracts

// The host and injected runtime share the full model. Imports, duplication and saves
// retain aspect ratios, both anchors, calibrations, layers and controller bindings.
typealias KeyModelTransform = MulgContracts.KeyModelTransform
typealias ButtonModel = MulgContracts.ButtonElement
typealias JoystickMode = MulgContracts.JoystickMode
typealias JoystickModel = MulgContracts.JoystickElement
typealias MouseAreaModel = MulgContracts.MouseAreaElement
typealias Keymap = MulgContracts.KeymappingData
typealias KeymapConfig = MulgContracts.KeymapConfig
