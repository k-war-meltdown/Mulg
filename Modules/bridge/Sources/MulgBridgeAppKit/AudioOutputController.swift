#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import CoreAudio
import AudioToolbox
import CryptoKit
import Darwin
import Foundation

/// Controls the device side only. CoreAudio retains conversion of each client's PCM buffers.
@MainActor
final class AudioOutputController {
    private struct Stream {
        let id: AudioStreamID
        let original: AudioStreamBasicDescription
        let desired: AudioStreamBasicDescription
    }
    private struct Listener {
        let object: AudioObjectID
        var address: AudioObjectPropertyAddress
        let block: AudioObjectPropertyListenerBlock
    }
    private var device = AudioDeviceID(kAudioObjectUnknown)
    private var originalRate: Double = 0
    private var desiredRate: Double = 0
    private var requestedRate: Double = 0
    private var requestedDepth = 0
    private var protected = true
    private var streams: [Stream] = []
    private var listeners: [Listener] = []
    private var reportHandler: ((NSDictionary) -> Void)?
    private var settle: Task<Void, Never>?
    private var lease: Int32 = -1
    private var changedDevice = false
    private var writeTimes: [Date] = []
    private var stopped = false
    private var blocked = false
    private var deviceName = "No output device"
    private var state = "waiting"
    private var message = "Waiting for the audio device."
    private var supportedRates: [Double] = []
    private var supportedDepths: [Int] = []
    private var leaseProblem = ""
    private var routeMonitored = false

    func configure(rate: Double, depth: Int, protect: Bool, report: @escaping (NSDictionary) -> Void) {
        stop(restore: true)
        stopped = false; blocked = false; changedDevice = false
        requestedRate = rate.isFinite && rate >= 0 ? rate : 0
        requestedDepth = [0, 24, 32].contains(depth) ? depth : 0
        protected = protect; reportHandler = report
        routeMonitored = listen(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice) { $0.attachRoute() }
        attachRoute()
    }

    func reassert() {
        guard !stopped else { return }
        scheduleVerification()
    }

    func stop(restore: Bool) {
        stopped = true
        settle?.cancel(); settle = nil
        removeListeners()
        restoreDeviceIfOwned(restore)
        releaseLease()
        streams = []; device = AudioDeviceID(kAudioObjectUnknown)
        reportHandler = nil
    }

    private func attachRoute() {
        guard !stopped else { return }
        let output: AudioDeviceID = read(AudioObjectID(kAudioObjectSystemObject),
            kAudioHardwarePropertyDefaultOutputDevice, initial: AudioDeviceID(kAudioObjectUnknown)) ?? AudioDeviceID(kAudioObjectUnknown)
        if output == device && output != kAudioObjectUnknown { scheduleVerification(); return }
        // A route change must not leave the old DAC in a format selected for this game.
        settle?.cancel()
        removeListeners(exceptSystem: true)
        restoreDeviceIfOwned(true)
        releaseLease()
        device = output; streams = []; writeTimes = []; blocked = false; changedDevice = false
        supportedRates = []; supportedDepths = []
        guard output != kAudioObjectUnknown,
              let baseline: Double = read(output, kAudioDevicePropertyNominalSampleRate, initial: 0.0), baseline > 0 else {
            state = "unavailable"; message = "No readable output device. Playback remains managed by macOS."
            deviceName = "No output device"; originalRate = 0; desiredRate = 0; publish(); return
        }
        originalRate = baseline; desiredRate = requestedRate > 0 ? requestedRate : baseline
        deviceName = string(output, kAudioObjectPropertyName) ?? "Audio output"
        let rateMonitored = listen(output, kAudioDevicePropertyNominalSampleRate) { $0.scheduleVerification() }
        listen(output, kAudioDevicePropertyStreams, scope: kAudioDevicePropertyScopeOutput) { $0.scheduleVerification() }
        let ranges: [AudioValueRange] = array(output, kAudioDevicePropertyAvailableNominalSampleRates) ?? []
        if let rate = Self.chooseRate(requested: requestedRate, baseline: baseline, ranges: ranges) { desiredRate = rate }
        supportedRates = [44_100.0, 48_000, 88_200, 96_000, 176_400, 192_000].filter { rate in
            ranges.contains { rate >= $0.mMinimum && rate <= $0.mMaximum }
        }
        if !supportedRates.contains(baseline) { supportedRates.append(baseline); supportedRates.sort() }
        guard protected else {
            state = "disabled"; message = "The game chooses its audio preference. Device format is reported as-is."
            publish(); return
        }
        guard routeMonitored && rateMonitored else {
            blocked = true; state = "unavailable"
            message = "CoreAudio device changes cannot be monitored on this route. Its format was left unchanged."
            publish(); return
        }
        guard abs(desiredRate - baseline) < 0.5 || ranges.contains(where: { desiredRate >= $0.mMinimum && desiredRate <= $0.mMaximum }) else {
            blocked = true; state = "unsupported"
            message = "This device does not advertise the requested sample rate. Its current format is kept."
            publish(); return
        }
        let ids: [AudioStreamID] = array(output, kAudioDevicePropertyStreams, scope: kAudioDevicePropertyScopeOutput) ?? []
        var depthSets: [Set<Int>] = []
        for id in ids {
            guard let original: AudioStreamBasicDescription = read(id, kAudioStreamPropertyPhysicalFormat,
                    initial: AudioStreamBasicDescription()), original.mFormatID == kAudioFormatLinearPCM else {
                blocked = true; state = "unsupported"; message = "This route does not expose a PCM output format."
                publish(); return
            }
            let choices: [AudioStreamRangedDescription] = array(id, kAudioStreamPropertyAvailablePhysicalFormats) ?? []
            let available = choices.filter {
                $0.mFormat.mFormatID == kAudioFormatLinearPCM && $0.mFormat.mChannelsPerFrame == original.mChannelsPerFrame
                    && desiredRate >= $0.mSampleRateRange.mMinimum && desiredRate <= $0.mSampleRateRange.mMaximum
            }
            var depths = Set(available.map { Int($0.mFormat.mBitsPerChannel) })
            if abs(original.mSampleRate - desiredRate) < 0.5 { depths.insert(Int(original.mBitsPerChannel)) }
            depthSets.append(depths)
            let bits = requestedDepth > 0 ? UInt32(requestedDepth) : original.mBitsPerChannel
            var chosen: AudioStreamBasicDescription?
            if bits == original.mBitsPerChannel && abs(original.mSampleRate - desiredRate) < 0.5 { chosen = original }
            if chosen == nil {
                chosen = available.filter { $0.mFormat.mBitsPerChannel == bits }
                    .sorted { a, b in
                        (a.mFormat.mFormatFlags == original.mFormatFlags ? 0 : 1)
                            < (b.mFormat.mFormatFlags == original.mFormatFlags ? 0 : 1)
                    }.first?.mFormat
            }
            guard var format = chosen else {
                blocked = true; state = "unsupported"
                message = "The requested rate and bit depth are not available together on this route. No lower format was substituted."
                publish(); return
            }
            format.mSampleRate = desiredRate
            streams.append(Stream(id: id, original: original, desired: format))
            guard listen(id, kAudioStreamPropertyPhysicalFormat, action: { $0.scheduleVerification() }) else {
                blocked = true; state = "unavailable"
                message = "CoreAudio cannot monitor this output stream. Its format was left unchanged."
                publish(); return
            }
        }
        supportedDepths = depthSets.dropFirst().reduce(depthSets.first ?? []) { $0.intersection($1) }.sorted()
        guard !streams.isEmpty else {
            blocked = true; state = "unsupported"; message = "The device exposes no writable PCM output streams."
            publish(); return
        }
        guard acquireLease(output) else {
            blocked = true; state = "conflict"; message = leaseProblem
            publish(); return
        }
        applyOrVerify()
    }

    /// iOS audio hardware runs at 48 or 44.1 kHz, so games are only built and tested at those rates.
    private nonisolated static let iPadNativeRates: [Double] = [48_000, 44_100]

    /// The requested rate when the device offers it (or already runs it). A DAC without the requested
    /// iPad-native rate gets the other one, rather than leaving the game at, say, 192 kHz. Nil keeps
    /// the request, which the caller then reports as unsupported.
    nonisolated static func chooseRate(requested: Double, baseline: Double, ranges: [AudioValueRange]) -> Double? {
        guard requested > 0 else { return baseline }
        let candidates = [requested] + (iPadNativeRates.contains(requested) ? iPadNativeRates.filter { $0 != requested } : [])
        return candidates.first { rate in
            abs(rate - baseline) < 0.5 || ranges.contains { rate >= $0.mMinimum && rate <= $0.mMaximum }
        }
    }

    private func scheduleVerification() {
        settle?.cancel()
        settle = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
            guard !Task.isCancelled, let self, !self.stopped else { return }
            self.applyOrVerify()
        }
    }

    private func currentMatchesDesired() -> Bool {
        guard let rate: Double = read(device, kAudioDevicePropertyNominalSampleRate, initial: 0.0),
              abs(rate - desiredRate) < 0.5 else { return false }
        guard let ids: [AudioStreamID] = array(device, kAudioDevicePropertyStreams, scope: kAudioDevicePropertyScopeOutput),
              Set(ids) == Set(streams.map(\.id)) else { return false }
        return !streams.isEmpty && streams.allSatisfy {
            guard let current: AudioStreamBasicDescription = read($0.id, kAudioStreamPropertyPhysicalFormat,
                initial: AudioStreamBasicDescription()) else { return false }
            return same(current, $0.desired)
        }
    }

    private func applyOrVerify() {
        guard !stopped else { return }
        guard protected && !blocked else { publish(); return }
        if currentMatchesDesired() {
            state = "applied"; message = "The output device is using the selected format."
            publish(); return
        }
        let now = Date()
        writeTimes.removeAll { now.timeIntervalSince($0) > 15 }
        guard writeTimes.count < 3 else {
            blocked = true; state = "conflict"
            message = "The device repeatedly rejected or replaced this format. Protection stopped to avoid repeated audio interruptions."
            publish(); return
        }
        writeTimes.append(now)
        guard let beforeRate: Double = read(device, kAudioDevicePropertyNominalSampleRate, initial: 0.0), beforeRate > 0 else {
            blocked = true; state = "unavailable"; message = "The output device is no longer readable. Playback remains managed by macOS."
            publish(); return
        }
        guard let ids: [AudioStreamID] = array(device, kAudioDevicePropertyStreams, scope: kAudioDevicePropertyScopeOutput),
              Set(ids) == Set(streams.map(\.id)) else {
            blocked = true; state = "unavailable"; message = "The output-stream layout changed. Reopen the game to reacquire this route."
            publish(); return
        }
        var before: [(AudioStreamID, AudioStreamBasicDescription)] = []
        for stream in streams {
            guard let format: AudioStreamBasicDescription = read(stream.id, kAudioStreamPropertyPhysicalFormat,
                initial: AudioStreamBasicDescription()) else {
                blocked = true; state = "unavailable"; message = "Output streams changed. Reopen the game to reacquire this route."
                publish(); return
            }
            before.append((stream.id, format))
        }
        var failure: OSStatus = noErr
        if abs(beforeRate - desiredRate) >= 0.5 { failure = write(device, kAudioDevicePropertyNominalSampleRate, desiredRate) }
        if failure == noErr {
            for stream in streams {
                let current: AudioStreamBasicDescription? = read(stream.id, kAudioStreamPropertyPhysicalFormat, initial: AudioStreamBasicDescription())
                if current.map({ same($0, stream.desired) }) != true {
                    failure = write(stream.id, kAudioStreamPropertyPhysicalFormat, stream.desired)
                    if failure != noErr { break }
                }
            }
        }
        if failure != noErr {
            // Restore the transaction's previous format rather than leaving a partial change.
            if beforeRate > 0 { _ = write(device, kAudioDevicePropertyNominalSampleRate, beforeRate) }
            for (id, format) in before { _ = write(id, kAudioStreamPropertyPhysicalFormat, format) }
            blocked = true; state = "unsupported"
            message = "CoreAudio rejected the format (\(failure)). The previous format was requested again; actual output is shown below."
            publish(); return
        }
        changedDevice = true
        state = "waiting"; message = "Waiting for the device to confirm its format."
        publish(); scheduleVerification()
    }

    private func publish() {
        let actual: Double = read(device, kAudioDevicePropertyNominalSampleRate, initial: 0.0) ?? 0
        let ids: [AudioStreamID] = array(device, kAudioDevicePropertyStreams, scope: kAudioDevicePropertyScopeOutput) ?? []
        let formats: [AudioStreamBasicDescription] = ids.compactMap { read($0, kAudioStreamPropertyPhysicalFormat, initial: AudioStreamBasicDescription()) }
        let depths = Set(formats.map { Int($0.mBitsPerChannel) })
        let bits = depths.count == 1 ? (depths.first ?? 0) : 0
        let floats = !formats.isEmpty && formats.allSatisfy { ($0.mFormatFlags & kAudioFormatFlagIsFloat) != 0 }
        let preference = protected ? ((state == "applied" || state == "waiting") && !blocked ? desiredRate : actual) : 0
        reportHandler?([
            "deviceName": deviceName, "requestedSampleRate": desiredRate, "sampleRate": actual,
            "preferredSessionRate": preference, "bitDepth": bits, "floatingPoint": floats,
            "availableSampleRates": supportedRates, "availableBitDepths": supportedDepths,
            "state": state, "message": message
        ] as NSDictionary)
    }

    private func restoreDeviceIfOwned(_ restore: Bool) {
        // Do not overwrite a format selected by another app/user after our last successful write.
        guard restore, changedDevice, lease >= 0, currentMatchesDesired(), originalRate > 0 else { return }
        _ = write(device, kAudioDevicePropertyNominalSampleRate, originalRate)
        for stream in streams { _ = write(stream.id, kAudioStreamPropertyPhysicalFormat, stream.original) }
        changedDevice = false
    }

    private func acquireLease(_ device: AudioDeviceID) -> Bool {
        leaseProblem = "Output-format coordination is unavailable. Its format was left unchanged."
        guard let uid = string(device, kAudioDevicePropertyDeviceUID) else { return false }
        let digest = SHA256.hash(data: Data(uid.utf8)).map { String(format: "%02x", $0) }.joined()
        let directory = Self.lockDirectory()
        // Made by the app when it prepares the game's sandbox; a missing folder is made here if the sandbox allows.
        if !FileManager.default.fileExists(atPath: directory.path) {
            do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false) }
            catch { leaseProblem = "Cannot access the audio coordination folder: \(error.localizedDescription)"; return false }
        }
        let descriptor = open(directory.appendingPathComponent(digest + ".lock").path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else {
            leaseProblem = "Cannot open the audio coordination lock (\(errno)). Its format was left unchanged."
            return false
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let failure = errno
            leaseProblem = failure == EWOULDBLOCK
                ? "Another Mulg game controls this output device. Its format is kept."
                : "Cannot coordinate this output device (\(failure)). Its format was left unchanged."
            close(descriptor); return false
        }
        lease = descriptor; return true
    }

    /// `~/Library/Containers/io.mulg.Mulg/Mulg/AudioOutput` (ContainerPaths.audioOutputLockDirectory), from the
    /// real home folder. Inside the game's sandbox homeDirectoryForCurrentUser is the game's own container, so
    /// every game locked a file of its own and two games never saw each other: both changed the device, and
    /// the first to quit restored it under the other.
    nonisolated static func lockDirectory() -> URL {
        var entry = passwd(), result: UnsafeMutablePointer<passwd>?
        var buffer = [CChar](repeating: 0, count: 16_384)
        let home: String? = buffer.withUnsafeMutableBufferPointer { storage in
            guard getpwuid_r(getuid(), &entry, storage.baseAddress, storage.count, &result) == 0, result != nil,
                  let directory = entry.pw_dir else { return nil }
            return String(cString: directory)
        }
        return URL(fileURLWithPath: home ?? NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library/Containers/io.mulg.Mulg/Mulg/AudioOutput", isDirectory: true)
    }

    private func releaseLease() {
        if lease >= 0 { flock(lease, LOCK_UN); close(lease); lease = -1 }
    }

    @discardableResult
    private func listen(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                        action: @escaping @MainActor @Sendable (AudioOutputController) -> Void) -> Bool {
        var address = property(selector, scope)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { if let self, !self.stopped { action(self) } }
        }
        if AudioObjectAddPropertyListenerBlock(object, &address, .main, block) == noErr {
            listeners.append(Listener(object: object, address: address, block: block))
            return true
        }
        return false
    }

    private func removeListeners(exceptSystem: Bool = false) {
        for var item in listeners where !exceptSystem || item.object != AudioObjectID(kAudioObjectSystemObject) {
            AudioObjectRemovePropertyListenerBlock(item.object, &item.address, .main, item.block)
        }
        listeners = exceptSystem ? listeners.filter { $0.object == AudioObjectID(kAudioObjectSystemObject) } : []
    }

    private func property(_ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private func read<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                         scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, initial: T) -> T? {
        var address = property(selector, scope), result = initial
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &result) { AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0) }
        return status == noErr && Int(size) == MemoryLayout<T>.size ? result : nil
    }

    /// Used only with CoreAudio's POD device IDs, ranges and format descriptions.
    private func array<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                          scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [T]? {
        var address = property(selector, scope), size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr,
              size <= 1_048_576, Int(size) % MemoryLayout<T>.stride == 0 else { return nil }
        if size == 0 { return [] }
        let capacity = Int(size) / MemoryLayout<T>.stride
        let pointer = UnsafeMutablePointer<T>.allocate(capacity: capacity)
        defer { pointer.deallocate() }
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, pointer) == noErr,
              Int(size) % MemoryLayout<T>.stride == 0, Int(size) / MemoryLayout<T>.stride <= capacity else { return nil }
        return Array(UnsafeBufferPointer(start: pointer, count: Int(size) / MemoryLayout<T>.stride))
    }

    private func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        let value: CFString? = read(object, selector, initial: Optional<CFString>.none) ?? nil
        return value.map { $0 as String }
    }

    private func write<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ value: T) -> OSStatus {
        var address = property(selector, kAudioObjectPropertyScopeGlobal), settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(object, &address, &settable) == noErr, settable.boolValue else {
            return kAudioHardwareIllegalOperationError
        }
        var value = value
        return withUnsafePointer(to: &value) { AudioObjectSetPropertyData(object, &address, 0, nil, UInt32(MemoryLayout<T>.size), $0) }
    }

    private func same(_ a: AudioStreamBasicDescription, _ b: AudioStreamBasicDescription) -> Bool {
        abs(a.mSampleRate - b.mSampleRate) < 0.5 && a.mFormatID == b.mFormatID && a.mFormatFlags == b.mFormatFlags
            && a.mBytesPerPacket == b.mBytesPerPacket && a.mFramesPerPacket == b.mFramesPerPacket
            && a.mBytesPerFrame == b.mBytesPerFrame && a.mChannelsPerFrame == b.mChannelsPerFrame && a.mBitsPerChannel == b.mBitsPerChannel
    }
}
#endif
