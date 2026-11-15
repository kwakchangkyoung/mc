import Foundation

/// Append-only operation log (Mole `~/Library/Logs/mole/operations.log` equivalent).
public final class OperationLog: @unchecked Sendable {
    public let url: URL
    private let lock = NSLock()
    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    public init(directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appendingPathComponent("operations.log")
    }

    public func record(_ command: String, _ action: String, _ path: String, _ detail: String? = nil) {
        // escape control characters so one record stays one line
        let safePath = path.unicodeScalars.map {
            CharacterSet.controlCharacters.contains($0) ? "\\u{\(String($0.value, radix: 16))}" : String($0)
        }.joined()
        var line = "[\(formatter.string(from: Date()))] [\(command)] \(action) \(safePath)"
        if let detail { line += " (\(detail))" }
        line += "\n"
        lock.lock()
        defer { lock.unlock() }
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }
}
