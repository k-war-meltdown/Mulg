//
//  SoundDeviceService.swift
//  Mulg
//

import CoreAudio
import Foundation

final class SoundDeviceService: Sendable {

    static let shared = SoundDeviceService()

    private init() { }

    private func getAudioPropertyAddress(
        selector: AudioObjectPropertySelector
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
    }

    private func getAudioPropertyData<T>(
        _ objectID: AudioObjectID,
        address: inout AudioObjectPropertyAddress,
        result: inout T
    ) -> OSStatus {
        var size = UInt32(MemoryLayout<T>.size)
        return withUnsafeMutablePointer(to: &result) { result in
            AudioObjectGetPropertyData(objectID, &address, UInt32(0), nil, &size, result)
        }
    }

    private func getSoundDevice() -> AudioDeviceID? {
        var address = getAudioPropertyAddress(selector: kAudioHardwarePropertyDefaultOutputDevice)
        var deviceID = AudioDeviceID()
        let objectID = AudioObjectID(kAudioObjectSystemObject)
        if getAudioPropertyData(objectID, address: &address, result: &deviceID) != noErr {
            return nil
        } else {
            return deviceID
        }
    }

    private func getSampleRate(_ deviceID: AudioObjectID) -> Float64? {
        var result = Float64(0.0)
        var address = getAudioPropertyAddress(selector: kAudioDevicePropertyNominalSampleRate)
        guard AudioObjectHasProperty(deviceID, &address) else { return nil }
        if getAudioPropertyData(deviceID, address: &address, result: &result) != noErr {
            return nil
        } else {
            return result
        }
    }

    /// Library startup reads the current format; only explicit per-game policy may change it.
    func prepareSoundDevice() {
        guard let device = getSoundDevice() else { return }
        if let sampleRate = getSampleRate(device) {
            Log.shared.log("Audio output: \(sampleRate / 1000) kHz; Audio MIDI format preserved")
        }
    }
}
