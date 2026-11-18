import SwiftUI
#if os(macOS)
import AppKit
import CoreAudio
#else
import UIKit
#endif

enum MenuBarMode: String, CaseIterable, Identifiable {
    case icon, percent, change, changeAndPercent, value

    var id: String { rawValue }

    var title: String {
        switch self {
        case .icon: return "Icon only"
        case .percent: return "Today's change in %"
        case .change: return "Today's gain or loss in €"
        case .changeAndPercent: return "Today's gain or loss in € and %"
        case .value: return "Total portfolio value"
        }
    }

    /// Whether this mode puts money amounts in the menu bar.
    var showsAmounts: Bool { self == .change || self == .changeAndPercent || self == .value }
}

#if os(macOS)
/// macOS has no public signal for "another app is capturing the screen", so this combines the
/// signals that do exist: a call in progress, a system screen-sharing session, or display mirroring.
enum PrivacySignals {
    static var isLikelySharing: Bool {
        microphoneInUse || screenIsShared || displayIsMirrored
    }

    /// True while any app uses the default microphone, which is the case during a call.
    static var microphoneInUse: Bool {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != 0
        else { return false }
        var running: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        address.mSelector = kAudioDevicePropertyDeviceIsRunningSomewhere
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &running) == noErr else { return false }
        return running != 0
    }

    /// True while someone views this Mac through macOS Screen Sharing.
    static var screenIsShared: Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return session["CGSSessionScreenIsShared"] as? Bool ?? false
    }

    /// True while the display is mirrored, for example to a projector or AirPlay.
    static var displayIsMirrored: Bool {
        CGDisplayIsInMirrorSet(CGMainDisplayID()) != 0
    }

    /// Asks the window server to leave this app's windows out of screen sharing and recordings.
    @MainActor
    static func excludeWindowsFromCapture(_ exclude: Bool) {
        for window in NSApp.windows {
            let wanted: NSWindow.SharingType = exclude ? .none : .readOnly
            if window.sharingType != wanted { window.sharingType = wanted }
        }
    }
}
#else
/// iOS reports directly whether the screen is being recorded, mirrored or shared.
enum PrivacySignals {
    @MainActor
    static var isLikelySharing: Bool {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .contains { $0.screen.isCaptured }
    }

    @MainActor
    static func excludeWindowsFromCapture(_ exclude: Bool) {}
}
#endif
