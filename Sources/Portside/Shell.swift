import Foundation

/// Run a command synchronously and capture raw stdout. Call off the main
/// thread. A hung tool (wedged lsof, dead mount) is SIGKILLed at the timeout
/// so the scan pipeline can never freeze permanently.
///
/// Returns nil when the tool could not run or did not finish — callers must
/// treat that as "unknown", never as "empty output".
func shellData(
    _ executable: String,
    _ arguments: [String],
    timeout: TimeInterval = 10
) -> Data? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments

    let out = Pipe()
    process.standardOutput = out
    process.standardError = FileHandle.nullDevice
    process.standardInput = FileHandle.nullDevice

    do {
        try process.run()
    } catch {
        return nil
    }

    let done = DispatchGroup()
    done.enter()
    var data = Data()
    DispatchQueue.global(qos: .utility).async {
        data = out.fileHandleForReading.readDataToEndOfFile()
        done.leave()
    }

    if done.wait(timeout: .now() + timeout) == .timedOut {
        process.terminate()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) {
            kill(process.processIdentifier, SIGKILL)
        }
        // Only touch `data` once the reader thread has finished with it.
        _ = done.wait(timeout: .now() + 3)
        return nil
    }
    process.waitUntilExit()
    // Not gated on exit status: lsof exits 1 when nothing matched, which is a
    // legitimate "no listeners", not a failure.
    return data
}
