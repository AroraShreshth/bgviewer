import Foundation

/// Tiny helper for running command-line tools and capturing their output.
enum Shell {
    struct Result {
        let out: String
        let err: String
        let code: Int32
        let timedOut: Bool
        var ok: Bool { code == 0 && !timedOut }
    }

    /// Run a tool and capture stdout + stderr.
    ///
    /// Both pipes are drained concurrently — draining them one after the other
    /// deadlocks if the child fills the second pipe's buffer while we're
    /// blocked on the first. A watchdog kills anything that outlives `timeout`
    /// seconds so one hung tool can never freeze a scan.
    @discardableResult
    static func run(_ path: String, _ args: [String], timeout: TimeInterval = 30) -> Result {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let outPipe = Pipe()
        let errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        p.standardInput = FileHandle.nullDevice
        do {
            try p.run()
        } catch {
            return Result(out: "", err: "\(error)", code: -1, timedOut: false)
        }

        final class Captured: @unchecked Sendable { var out = Data(); var err = Data() }
        let captured = Captured()
        let readers = DispatchGroup()
        readers.enter()
        DispatchQueue.global().async {
            captured.out = outPipe.fileHandleForReading.readDataToEndOfFile()
            readers.leave()
        }
        readers.enter()
        DispatchQueue.global().async {
            captured.err = errPipe.fileHandleForReading.readDataToEndOfFile()
            readers.leave()
        }

        let exited = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            p.waitUntilExit()
            exited.signal()
        }

        var timedOut = false
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            p.terminate()
            if exited.wait(timeout: .now() + 2) == .timedOut {
                kill(p.processIdentifier, SIGKILL)
                exited.wait()
            }
        }
        readers.wait()
        return Result(out: String(decoding: captured.out, as: UTF8.self),
                      err: String(decoding: captured.err, as: UTF8.self),
                      code: p.terminationStatus,
                      timedOut: timedOut)
    }

    @discardableResult
    static func sh(_ cmd: String, timeout: TimeInterval = 30) -> Result {
        run("/bin/sh", ["-c", cmd], timeout: timeout)
    }
}
