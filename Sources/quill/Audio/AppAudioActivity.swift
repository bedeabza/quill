import CoreAudio
import Foundation

/// Whether an app is running audio input or output right now, read from Core
/// Audio's per-process state. Nothing is captured. An unreadable state is false.
enum AppAudioActivity {
    static func isRunning(pid: pid_t, bundleID: String?) -> Bool {
        processObjects().contains { object in
            guard read(object, kAudioProcessPropertyPID, pid_t(-1)) == pid || belongs(bundle(object), to: bundleID) else { return false }
            return read(object, kAudioProcessPropertyIsRunning, UInt32(0)) != 0
        }
    }

    /// Helper processes carry the app's bundle identifier as a prefix.
    static func belongs(_ bundle: String, to appBundleID: String?) -> Bool {
        guard let appBundleID, !appBundleID.isEmpty, !bundle.isEmpty else { return false }
        return bundle == appBundleID || bundle.hasPrefix(appBundleID + ".")
    }

    private static func bundle(_ object: AudioObjectID) -> String {
        var address = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyBundleID, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr, let value else { return "" }
        return value.takeRetainedValue() as String
    }

    private static func processObjects() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &objects) == noErr else { return [] }
        return Array(objects.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    private static func read<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ fallback: T) -> T {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value = fallback
        var size = UInt32(MemoryLayout<T>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return fallback }
        return value
    }
}
