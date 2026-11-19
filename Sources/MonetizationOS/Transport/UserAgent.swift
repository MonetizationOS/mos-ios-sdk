import Foundation

/// `<appName>/<appVersion> (<platform> <osVersion>; <device>) MOS-iOS/<sdkVersion>`.
/// Set deliberately: MOS tags tool-like agents as bots, and a bot-tagged request silently
/// loses every anonymous-session plan. It also tells app traffic from web traffic.
/// Sanitised as the Android SDK does, so the same inputs give the same header on both.
enum UserAgent {
    static func make(appName: String, appVersion: String, platform: String = platform, osVersion: String = osVersion, device: String = device) -> String {
        let os = [platform, osVersion].map(comment).filter { !$0.isEmpty }.joined(separator: " ")
        return "\(token(appName))/\(token(appVersion)) (\(os); \(comment(device))) MOS-iOS/\(MOSVersion)"
    }

    private static let tokenCharacters = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789!#$%&'*+.^_`|~-".unicodeScalars)

    /// An HTTP token: each run of other characters becomes one `-`, `-` is trimmed from both ends,
    /// and nothing left is `app`.
    static func token(_ value: String) -> String {
        var out = String.UnicodeScalarView()
        var inRun = false
        for scalar in value.unicodeScalars {
            if tokenCharacters.contains(scalar) {
                out.append(scalar)
                inRun = false
            } else if !inRun {
                out.append("-")
                inRun = true
            }
        }
        let trimmed = String(out).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "app" : trimmed
    }

    /// Comment text: printable ASCII without `(`, `)`, `;` or `\`, trimmed of spaces.
    static func comment(_ value: String) -> String {
        let kept = value.unicodeScalars.filter { (0x20...0x7E).contains($0.value) && !"();\\".unicodeScalars.contains($0) }
        return String(kept).trimmingCharacters(in: CharacterSet(charactersIn: " "))
    }

    static var platform: String {
        #if os(iOS)
        "iOS"
        #elseif os(tvOS)
        "tvOS"
        #elseif os(visionOS)
        "visionOS"
        #elseif os(watchOS)
        "watchOS"
        #else
        "macOS"
        #endif
    }

    static var osVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let base = "\(version.majorVersion).\(version.minorVersion)"
        return version.patchVersion > 0 ? "\(base).\(version.patchVersion)" : base
    }

    /// The hardware model (`iPhone15,2`). Read through `uname` rather than `UIDevice`, which is
    /// main-actor isolated and would force construction onto the main thread.
    static var device: String {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { return simulated }
        var system = utsname()
        uname(&system)
        let machine = withUnsafeBytes(of: &system.machine) { bytes in
            String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        #if os(macOS)
        return "Mac"
        #else
        return machine.isEmpty ? "Unknown" : machine
        #endif
    }
}
