import Darwin
import XCTest
@testable import Portside

final class LauncherTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("portside-launch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private var logURL: URL { tempDir.appendingPathComponent("run.log") }
    private let plainEnv = ["PATH": "/usr/bin:/bin"]

    private func waitForExit(_ pid: pid_t, timeout: TimeInterval = 10) -> Int32? {
        let deadline = Date().addingTimeInterval(timeout)
        var status: Int32 = 0
        while Date() < deadline {
            let result = waitpid(pid, &status, WNOHANG)
            if result == pid { return status }
            usleep(50_000)
        }
        return nil
    }

    // MARK: - PATH augmentation

    func testAugmentedAddsStandardDirsWhenMissing() {
        let path = Launcher.augmented(["PATH": "/usr/bin"])["PATH"]!
        XCTAssertTrue(path.split(separator: ":").contains("/opt/homebrew/bin"))
        XCTAssertTrue(path.split(separator: ":").contains("/usr/local/bin"))
    }

    func testAugmentedDoesNotDuplicateOrReorderExistingEntries() {
        let original = "/opt/homebrew/bin:/usr/bin:/bin"
        let path = Launcher.augmented(["PATH": original])["PATH"]!
        XCTAssertTrue(path.hasPrefix(original), "user's PATH order must be preserved")
        XCTAssertEqual(
            path.split(separator: ":").filter { $0 == "/opt/homebrew/bin" }.count, 1
        )
    }

    func testSemverParts() {
        XCTAssertEqual(Launcher.semverParts("v20.11.1"), [20, 11, 1])
        XCTAssertTrue(
            Launcher.semverParts("v9.9.9").lexicographicallyPrecedes(Launcher.semverParts("v20.0.0"))
        )
    }

    func testLatestNvmBinPicksHighestVersion() throws {
        for version in ["v18.19.0", "v20.11.1", "v9.9.9"] {
            try FileManager.default.createDirectory(
                at: tempDir.appendingPathComponent(".nvm/versions/node/\(version)/bin"),
                withIntermediateDirectories: true
            )
        }
        XCTAssertEqual(
            Launcher.latestNvmBin(home: tempDir.path),
            tempDir.path + "/.nvm/versions/node/v20.11.1/bin"
        )
        XCTAssertNil(Launcher.latestNvmBin(home: tempDir.path + "/nope"))
    }

    // MARK: - Spawn integration

    func testExitCodeIsCaptured() throws {
        let pid = try Launcher.spawnShell(
            command: "exit 7", directory: tempDir.path,
            logURL: logURL, environment: plainEnv
        )
        guard let status = waitForExit(pid) else { return XCTFail("never exited") }
        XCTAssertEqual(AppModel.decodeExitStatus(status), 7)
    }

    func testRunsInRequestedDirectoryAndLogsOutput() throws {
        let pid = try Launcher.spawnShell(
            command: "pwd", directory: tempDir.path,
            logURL: logURL, environment: plainEnv
        )
        _ = waitForExit(pid)
        let log = try String(contentsOf: logURL, encoding: .utf8)
        XCTAssertTrue(log.contains("$ pwd"), "header must record the command")
        XCTAssertTrue(
            log.contains(tempDir.lastPathComponent),
            "command must run inside the requested directory"
        )
    }

    func testLogFileIsPrivate() throws {
        let pid = try Launcher.spawnShell(
            command: "exit 0", directory: tempDir.path,
            logURL: logURL, environment: plainEnv
        )
        _ = waitForExit(pid)
        let attrs = try FileManager.default.attributesOfItem(atPath: logURL.path)
        XCTAssertEqual(((attrs[.posixPermissions] as? Int) ?? 0) & 0o777, 0o600)
    }

    func testSymlinkedLogIsRefused() throws {
        let victim = tempDir.appendingPathComponent("victim.txt")
        try "precious".write(to: victim, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: logURL, withDestinationURL: victim)
        XCTAssertThrowsError(try Launcher.spawnShell(
            command: "echo pwned", directory: tempDir.path,
            logURL: logURL, environment: plainEnv
        ))
        XCTAssertEqual(try String(contentsOf: victim, encoding: .utf8), "precious")
    }

    func testOversizedLogRotates() throws {
        try Data(repeating: 0x61, count: 6_000_000).write(to: logURL)
        let pid = try Launcher.spawnShell(
            command: "exit 0", directory: tempDir.path,
            logURL: logURL, environment: plainEnv
        )
        _ = waitForExit(pid)
        let old = logURL.deletingPathExtension().appendingPathExtension("old.log")
        XCTAssertTrue(FileManager.default.fileExists(atPath: old.path))
        let attrs = try FileManager.default.attributesOfItem(atPath: logURL.path)
        XCTAssertLessThan((attrs[.size] as? Int) ?? .max, 100_000)
    }

    func testGroupKillTakesDownTheWholeTree() throws {
        let pid = try Launcher.spawnShell(
            command: "sleep 30 & sleep 30 & wait", directory: tempDir.path,
            logURL: logURL, environment: plainEnv
        )
        // Wait until BOTH sleeps actually exist in the group — killing before
        // they spawn would make the survivors-check pass vacuously.
        var members: [pid_t] = []
        let spawnDeadline = Date().addingTimeInterval(8)
        while Date() < spawnDeadline {
            let out = shellData("/usr/bin/pgrep", ["-g", "\(pid)"]) ?? Data()
            members = String(decoding: out, as: UTF8.self)
                .split(separator: "\n").compactMap { pid_t($0) }
            if members.count >= 3 { break } // zsh + 2 sleeps
            usleep(100_000)
        }
        XCTAssertGreaterThanOrEqual(members.count, 3,
                                    "children must exist before the kill")

        Launcher.terminateGroup(pid)
        _ = waitForExit(pid, timeout: 5)

        // Every member — including the backgrounded sleeps — must be gone.
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, kill(-pid, 0) == 0 { usleep(100_000) }
        XCTAssertNotEqual(kill(-pid, 0), 0, "no survivors in the group")
        for member in members {
            XCTAssertNotEqual(kill(member, 0), 0, "pid \(member) survived group kill")
        }
    }

    func testChildLeadsItsOwnProcessGroup() throws {
        let pid = try Launcher.spawnShell(
            command: "sleep 5", directory: tempDir.path,
            logURL: logURL, environment: plainEnv
        )
        defer {
            Launcher.terminateGroup(pid)
            _ = waitForExit(pid, timeout: 3)
        }
        XCTAssertEqual(getpgid(pid), pid, "child must lead a fresh group")
        XCTAssertNotEqual(getpgid(pid), getpgid(getpid()),
                          "…separate from ours, or group-kill would hit Portside")
    }
}
