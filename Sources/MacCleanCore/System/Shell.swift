import Foundation

/// Runs an external command with a timeout and `LC_ALL=C` (Mole `run_with_timeout`).
public enum Shell {
    public struct Result: Sendable {
        public let status: Int32
        public let stdout: String
        public let timedOut: Bool
    }

    private final class Box: @unchecked Sendable { var data = Data() }

    public static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        env["LC_ALL"] = "C"
        process.environment = env
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() } catch { return Result(status: -1, stdout: "", timedOut: false) }

        // read on another thread so a full pipe cannot block the child
        let box = Box()
        let readDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            box.data = out.fileHandleForReading.readDataToEndOfFile()
            readDone.signal()
        }
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()   // SIGTERM, then SIGKILL after a short grace period
            if exited.wait(timeout: .now() + 1) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + 1)
            }
            _ = readDone.wait(timeout: .now() + 1)
            return Result(status: 124, stdout: "", timedOut: true)
        }
        // a readDone timeout means the reader thread may still be writing box.data —
        // do not touch it
        if readDone.wait(timeout: .now() + 2) == .timedOut {
            return Result(status: process.terminationStatus, stdout: "", timedOut: false)
        }
        return Result(status: process.terminationStatus, stdout: String(decoding: box.data, as: UTF8.self),
                      timedOut: false)
    }
}
