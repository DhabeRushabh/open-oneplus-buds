import Foundation
import CoreAudio
import os

/// Manages macOS CoreAudio device selection to force Bluetooth earbuds (such as OnePlus Buds)
/// to remain strictly an audio output device. This prevents macOS from engaging the low-quality
/// 16kHz mono hands-free profile (HFP/SCO) when apps request a microphone.
public final class AudioDeviceManager: @unchecked Sendable {
    public static let shared = AudioDeviceManager()

    private let queue = DispatchQueue(label: "com.buds.audiomanager")
    private let lock = OSAllocatedUnfairLock(initialState: false)

    private var isInputListenerRegistered = false
    private var isOutputListenerRegistered = false
    private var listenerBlock: AudioObjectPropertyListenerBlock?

    public var isEnforced: Bool {
        lock.withLock { $0 }
    }

    private var defaultInputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    private var defaultOutputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    private init() {}

    deinit {
        stopMonitoring()
    }

    /// Enables or disables forced output-only mode.
    public func setForceOutputOnly(_ enabled: Bool) {
        lock.withLock { $0 = enabled }
        queue.async { [weak self] in
            guard let self else { return }
            if enabled {
                self.enforceNow()
                self.startMonitoring()
            } else {
                self.stopMonitoring()
            }
        }
    }

    /// Enforces non-Bluetooth input immediately if output and input are both Bluetooth / Buds.
    @discardableResult
    public func enforceNow() -> Bool {
        guard let currentInputID = Self.getDefaultInputDeviceID(),
              let currentOutputID = Self.getDefaultOutputDeviceID() else {
            return false
        }

        // Only redirect when output is Bluetooth (e.g. OnePlus Buds) and input is also Bluetooth,
        // which prevents Bluetooth audio degradation without hijacking mics when listening via speakers.
        if Self.isBluetoothOrBudsDevice(currentOutputID) && Self.isBluetoothOrBudsDevice(currentInputID) {
            if let fallbackID = Self.getPreferredInputDeviceID() {
                return Self.setDefaultInputDeviceID(fallbackID)
            }
        }
        return false
    }

    // MARK: - CoreAudio Device Helpers

    public static func getDefaultOutputDeviceID() -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &addr,
            0,
            nil,
            &size,
            &id
        )
        return status == noErr ? id : nil
    }

    public static func getDefaultInputDeviceID() -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &addr,
            0,
            nil,
            &size,
            &id
        )
        return status == noErr ? id : nil
    }

    public static func getDeviceName(_ id: AudioDeviceID) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var cfName: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &cfName)
        if status == noErr, let unmanaged = cfName {
            return unmanaged.takeRetainedValue() as String
        }
        return nil
    }

    public static func isBluetoothOrBudsDevice(_ id: AudioDeviceID) -> Bool {
        var transportAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        if AudioObjectGetPropertyData(id, &transportAddr, 0, nil, &size, &transport) == noErr {
            // 'blue' = 0x626c7565 = 1651275109 (Bluetooth Classic A2DP / HFP)
            // 'ble ' = 0x626c6520 = 1651270944 (Bluetooth Low Energy Audio)
            if transport == kAudioDeviceTransportTypeBluetooth ||
               transport == kAudioDeviceTransportTypeBluetoothLE ||
               transport == 1651275109 ||
               transport == 1651270944 {
                return true
            }
        }

        if let name = getDeviceName(id)?.lowercased() {
            let keywords = ["buds", "oneplus", "nord", "enco", "oppo"]
            if keywords.contains(where: { name.contains($0) }) {
                return true
            }
        }
        return false
    }

    public static func getPreferredInputDeviceID() -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else {
            return nil
        }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else {
            return nil
        }

        var builtInID: AudioDeviceID?
        var otherNonBluetoothID: AudioDeviceID?

        for id in ids {
            // Must have input streams
            var streamAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: kAudioObjectPropertyElementWildcard
            )
            var streamSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &streamAddr, 0, nil, &streamSize) == noErr, streamSize > 0 else {
                continue
            }

            // Exclude any Bluetooth or earbuds device
            guard !isBluetoothOrBudsDevice(id) else { continue }

            var transportAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyTransportType,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var transport: UInt32 = 0
            var tSize = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectGetPropertyData(id, &transportAddr, 0, nil, &tSize, &transport) == noErr {
                if transport == kAudioDeviceTransportTypeBuiltIn {
                    builtInID = id
                    break
                }
            }
            if otherNonBluetoothID == nil {
                otherNonBluetoothID = id
            }
        }

        return builtInID ?? otherNonBluetoothID
    }

    public static func setDefaultInputDeviceID(_ id: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var targetID = id
        let size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &addr,
            0,
            nil,
            size,
            &targetID
        )
        return status == noErr
    }

    // MARK: - OS Property Listener (Event-driven, no polling)

    private func startMonitoring() {
        let block: AudioObjectPropertyListenerBlock = listenerBlock ?? { [weak self] _, _ in
            guard let self, self.isEnforced else { return }
            self.enforceNow()
        }
        listenerBlock = block

        if !isInputListenerRegistered {
            let inStatus = AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &defaultInputAddress,
                queue,
                block
            )
            if inStatus == noErr {
                isInputListenerRegistered = true
            }
        }

        if !isOutputListenerRegistered {
            let outStatus = AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &defaultOutputAddress,
                queue,
                block
            )
            if outStatus == noErr {
                isOutputListenerRegistered = true
            }
        }
    }

    private func stopMonitoring() {
        guard let block = listenerBlock else { return }
        if isInputListenerRegistered {
            _ = AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &defaultInputAddress,
                queue,
                block
            )
            isInputListenerRegistered = false
        }
        if isOutputListenerRegistered {
            _ = AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &defaultOutputAddress,
                queue,
                block
            )
            isOutputListenerRegistered = false
        }
        if !isInputListenerRegistered && !isOutputListenerRegistered {
            listenerBlock = nil
        }
    }
}

