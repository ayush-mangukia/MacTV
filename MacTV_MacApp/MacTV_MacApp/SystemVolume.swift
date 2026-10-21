import CoreAudio
import AudioToolbox
import Observation
import AppKit
import ApplicationServices

/// CoreAudio controls the current default output, without requiring Accessibility.
@MainActor @Observable
final class SystemVolume {
    private(set) var level: Double = 100
    private(set) var muted = false
    private(set) var available = false
    private(set) var notice: String?
    private(set) var outputName = "Mac output"
    private var nativeAvailable = false
    var monitorControlRunning: Bool { NSWorkspace.shared.runningApplications.contains { ["app.monitorcontrol.MonitorControl", "me.guillaumeb.MonitorControl"].contains($0.bundleIdentifier ?? "") } }
    static func mediaEvents(_ code: Int) -> [CGEvent] {
        [true, false].compactMap { down in
            let state = down ? 0xa00 : 0xb00
            return NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(state)), timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: 0, context: nil, subtype: 8, data1: (code << 16) | state, data2: -1)?.cgEvent
        }
    }
    private func monitorKey(_ code: Int) -> Bool {
        guard monitorControlRunning else { return false }
        guard CGPreflightPostEventAccess() else { notice = RemoteInput.permissionMessage; return false }
        let events = Self.mediaEvents(code)
        guard events.count == 2 else { return false }
        for event in events { event.post(tap: .cghidEventTap) }
        return true // Dispatched to MonitorControl; its hardware volume is not guessed.
    }
    private let simulated: Bool
    init(simulated: Bool = false) { self.simulated = simulated; if simulated { available = true } else { refresh() } }
    private func address(_ selector: AudioObjectPropertySelector, _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeOutput, mElement: element)
    }
    private func device() -> AudioDeviceID? {
        var property = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0); var size = UInt32(MemoryLayout.size(ofValue: id))
        return AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &property, 0, nil, &size, &id) == noErr && id != 0 ? id : nil
    }
    private func volumeSelector(_ id: AudioDeviceID) -> AudioObjectPropertySelector {
        var p = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        return AudioObjectHasProperty(id, &p) ? kAudioHardwareServiceDeviceProperty_VirtualMainVolume : kAudioDevicePropertyVolumeScalar
    }
    private func channels(_ id: AudioDeviceID) -> [AudioObjectPropertyElement] {
        // Prefer main volume; otherwise inspect the actual channel count (including multichannel outputs).
        var property = address(volumeSelector(id))
        if AudioObjectHasProperty(id, &property) { return [kAudioObjectPropertyElementMain] }
        property = address(kAudioDevicePropertyStreamConfiguration)
        var bytes: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &property, 0, nil, &bytes) == noErr, bytes >= MemoryLayout<AudioBufferList>.size else { return [] }
        let memory = UnsafeMutableRawPointer.allocate(byteCount: Int(bytes), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { memory.deallocate() }
        guard AudioObjectGetPropertyData(id, &property, 0, nil, &bytes, memory) == noErr else { return [] }
        let count = UnsafeMutableAudioBufferListPointer(memory.assumingMemoryBound(to: AudioBufferList.self)).reduce(0) { $0 + Int($1.mNumberChannels) }
        return count > 0 ? (1...count).map { AudioObjectPropertyElement($0) }.filter { element in
            var p = address(volumeSelector(id), element); return AudioObjectHasProperty(id, &p)
        } : []
    }
    func refresh() {
        guard !simulated else { return }
        guard let id = device() else { available = false; notice = "No audio output is available"; return }
        var nameAddress = address(kAudioObjectPropertyName); nameAddress.mScope = kAudioObjectPropertyScopeGlobal
        var name: Unmanaged<CFString>?; var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        if AudioObjectGetPropertyData(id, &nameAddress, 0, nil, &nameSize, &name) == noErr, let name { outputName = name.takeRetainedValue() as String }
        let elements = channels(id)
        var values: [Double] = []
        var writable = !elements.isEmpty
        for element in elements {
            var property = address(volumeSelector(id), element); var value: Float32 = 0; var bytes: UInt32 = 4; var canSet: DarwinBoolean = false
            if AudioObjectGetPropertyData(id, &property, 0, nil, &bytes, &value) == noErr { values.append(Double(value) * 100) }
            writable = writable && AudioObjectIsPropertySettable(id, &property, &canSet) == noErr && canSet.boolValue
        }
        if !values.isEmpty { level = values.reduce(0, +) / Double(values.count) }
        var property = address(kAudioDevicePropertyMute); var value: UInt32 = 0; var bytes: UInt32 = 4
        muted = AudioObjectGetPropertyData(id, &property, 0, nil, &bytes, &value) == noErr && value != 0
        nativeAvailable = writable && !values.isEmpty
        available = nativeAvailable || (monitorControlRunning && CGPreflightPostEventAccess())
        notice = nativeAvailable ? nil : monitorControlRunning ? "Volume keys use MonitorControl · \(outputName)" : "\(outputName) has no macOS volume control. Use the display/speaker controls or choose another Mac sound output."
    }
    @discardableResult func set(_ value: Double) -> Bool {
        guard value.isFinite else { return false }
        if simulated { level = min(100, max(0, value)); return true }
        refresh(); guard nativeAvailable, let id = device() else { return false }
        var success = true
        for element in channels(id) {
            var property = address(volumeSelector(id), element); var scalar = Float32(min(100, max(0, value)) / 100)
            if AudioObjectSetPropertyData(id, &property, 0, nil, 4, &scalar) != noErr { success = false }
        }
        refresh(); return success
    }
    @discardableResult func change(_ delta: Double) -> Bool {
        refresh()
        if !simulated && !nativeAvailable { return monitorKey(delta > 0 ? 0 : 1) }
        return set(level + delta)
    }
    @discardableResult func toggleMute() -> Bool {
        if simulated { muted.toggle(); return true }
        refresh()
        if !nativeAvailable, monitorControlRunning { return monitorKey(7) }
        guard let id = device() else { return false }
        var property = address(kAudioDevicePropertyMute); var writable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(id, &property, &writable) == noErr, writable.boolValue else { notice = "This output does not support system mute"; return false }
        var value: UInt32 = muted ? 0 : 1
        let ok = AudioObjectSetPropertyData(id, &property, 0, nil, 4, &value) == noErr
        refresh(); return ok
    }
}
