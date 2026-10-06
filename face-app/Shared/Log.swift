import Foundation
import os

/// Logging to two places at once:
///  - a fixed file you can always review: ~/BuddyData/logs/face.log on the Mac
///    (rotates to face.log.1 at 5 MB). On the iPad it's the app's Documents/face.log.
///  - unified logging (Console.app, or
///    /usr/bin/log stream --predicate 'subsystem == "local.deskbuddy.face"').
enum Log {
    static let subsystem = "local.deskbuddy.face"
    static let app = BuddyLogger(category: "app")
    static let link = BuddyLogger(category: "link")
    static let audio = BuddyLogger(category: "audio")

    static var fileURL: URL { LogFile.shared.url }

    /// Record the reason for uncaught Objective-C exceptions before the process dies,
    /// since crash reports often leave it out.
    static func installCrashLogging() {
        NSSetUncaughtExceptionHandler { exception in
            LogFile.shared.writeSync("CRASH uncaught exception \(exception.name.rawValue): \(exception.reason ?? "")\n"
                + exception.callStackSymbols.prefix(15).joined(separator: "\n"))
        }
    }
}

struct BuddyLogger {
    let category: String
    private let os: Logger

    init(category: String) {
        self.category = category
        os = Logger(subsystem: Log.subsystem, category: category)
    }

    func debug(_ message: String) { write(.debug, "DEBUG", message) }
    func info(_ message: String) { write(.info, "INFO", message) }
    func notice(_ message: String) { write(.default, "NOTICE", message) }
    func error(_ message: String) { write(.error, "ERROR", message) }

    private func write(_ type: OSLogType, _ level: String, _ message: String) {
        os.log(level: type, "\(message, privacy: .public)")
        LogFile.shared.write("[\(category)] \(level) \(message)")
    }
}

/// Append-only log file with simple size-based rotation. All writes go through one
/// serial queue so lines never interleave.
final class LogFile {
    static let shared = LogFile()

    let url: URL
    private let queue = DispatchQueue(label: "LogFile")
    private var handle: FileHandle?
    private let maxBytes: UInt64 = 5 * 1024 * 1024
    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private init() {
        url = Self.logDirectory().appendingPathComponent("face.log")
    }

    func write(_ line: String) {
        let stamped = "\(formatter.string(from: Date())) \(line)\n"
        queue.async { self.append(stamped) }
    }

    func writeSync(_ line: String) {
        let stamped = "\(formatter.string(from: Date())) \(line)\n"
        queue.sync { self.append(stamped) }
    }

    private func append(_ text: String) {
        if handle == nil { open() }
        guard let handle, let data = text.data(using: .utf8) else { return }
        handle.write(data)
        if (try? handle.offset()) ?? 0 > maxBytes { rotate() }
    }

    private func open() {
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
        handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
    }

    private func rotate() {
        try? handle?.close()
        handle = nil
        let old = url.appendingPathExtension("1")
        try? FileManager.default.removeItem(at: old)
        try? FileManager.default.moveItem(at: url, to: old)
        open()
    }

    private static func logDirectory() -> URL {
        #if os(iOS)
        // The iPad keeps nothing important; this is just for debugging the face.
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        #else
        // Same folder as the brain's logs. Honors $BUDDY_DATA like brain/config.py.
        let data = ProcessInfo.processInfo.environment["BUDDY_DATA"].map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("BuddyData")
        return data.appendingPathComponent("logs")
        #endif
    }
}
