import Foundation
#if os(iOS)
import UIKit
#else
import AppKit
#endif

enum BuildInfo {
    /// When this build was installed. The executable's modification time is reset on
    /// every Xcode install, which is exactly the moment the 7-day free signing starts.
    static var buildDate: Date {
        guard let url = Bundle.main.executableURL,
              let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let date = attrs[.modificationDate] as? Date
        else { return Date() }
        return date
    }

    static var platform: String {
        #if os(iOS)
        "iPadOS"
        #else
        "macOS"
        #endif
    }

    @MainActor static var screen: [Int] {
        #if os(iOS)
        let size = UIScreen.main.bounds.size
        #else
        let size = NSScreen.main?.frame.size ?? .zero
        #endif
        return [Int(size.width), Int(size.height)]
    }

    static func hello(screen: [Int]) -> [String: Any] {
        [
            "build_date": ISO8601DateFormatter().string(from: buildDate),
            "platform": platform,
            "screen": screen,
        ]
    }
}
