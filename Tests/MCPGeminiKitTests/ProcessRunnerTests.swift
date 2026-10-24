import XCTest
@testable import MCPGeminiKit

final class ProcessRunnerTests: XCTestCase {
    private let env = Locator.environment()
    private let tmp = FileManager.default.temporaryDirectory

    private func sh(_ script: String, timeout: TimeInterval = 20, markers: [String] = []) async throws -> ProcessResult {
        try await ProcessRunner.run(executable: "/bin/sh", arguments: ["-c", script], environment: env,
                                    workingDirectory: tmp, timeout: timeout, abortMarkers: markers)
    }

    func testCapturesOutputAndExitCode() async throws {
        let r = try await sh("echo bonjour; echo erreur >&2; exit 3")
        XCTAssertEqual(r.stdout, "bonjour\n")
        XCTAssertEqual(r.stderr, "erreur\n")
        XCTAssertEqual(r.exitCode, 3)
        XCTAssertFalse(r.timedOut)
    }

    func testStdinIsClosed() async throws {
        let r = try await sh("cat; echo fin")
        XCTAssertEqual(r.stdout, "fin\n")
    }

    func testLargeOutputOnBothPipesDoesNotDeadlock() async throws {
        // Bien plus que la capacité d'un tube (64 Ko) des deux côtés à la fois.
        let r = try await sh("i=0; while [ $i -lt 20000 ]; do echo 0123456789012345678901234567890123456789; echo 0123456789012345678901234567890123456789 >&2; i=$((i+1)); done")
        XCTAssertEqual(r.stdout.count, 20000 * 41)
        XCTAssertEqual(r.stderr.count, 20000 * 41)
    }

    func testTimeoutKillsTheProcess() async throws {
        let start = Date()
        let r = try await sh("sleep 30", timeout: 0.5)
        XCTAssertTrue(r.timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(start), 10)
    }

    func testCancellationKillsTheProcess() async throws {
        let start = Date()
        let task = Task { try await self.sh("sleep 30") }
        try await Task.sleep(nanoseconds: 300_000_000)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("annulation attendue")
        } catch is CancellationError {}
        XCTAssertLessThan(Date().timeIntervalSince(start), 10)
    }

    func testAbortMarkerStopsEarly() async throws {
        let start = Date()
        let r = try await sh("echo 'Authentication required'; sleep 30", markers: ["Authentication required"])
        XCTAssertEqual(r.abortedOn, "Authentication required")
        XCTAssertLessThan(Date().timeIntervalSince(start), 10)
    }

    func testGrandchildHoldingThePipeDoesNotHangForever() async throws {
        let start = Date()
        let r = try await sh("(sleep 8 &) ; echo fini")
        XCTAssertEqual(r.stdout, "fini\n")
        XCTAssertLessThan(Date().timeIntervalSince(start), 6)
    }

    func testLaunchFailure() async {
        do {
            _ = try await ProcessRunner.run(executable: "/nonexistent/prog", arguments: [], environment: env,
                                            workingDirectory: tmp, timeout: 5)
            XCTFail("échec attendu")
        } catch let error as ProcessError {
            XCTAssertTrue(error.localizedDescription.contains("/nonexistent/prog"))
        } catch { XCTFail("\(error)") }
    }

    func testCancelledBeforeStart() async {
        let task = Task { () -> ProcessResult in
            try await Task.sleep(nanoseconds: 200_000_000)
            return try await self.sh("echo jamais")
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail()
        } catch is CancellationError {} catch { XCTFail("\(error)") }
    }

    func testMarkerInsideALegitimateJSONAnswerIsIgnored() async throws {
        let json = #"{"response":"Pour corriger : Authentication required signifie…","status":"SUCCESS"}"#
        let r = try await sh("printf '%s' '\(json)'", markers: ["Authentication required"])
        XCTAssertNil(r.abortedOn)
        XCTAssertEqual(r.stdout, json)
    }

    func testMarkerInALongOutputIsIgnored() async throws {
        let r = try await sh("i=0; while [ $i -lt 400 ]; do echo ligne-de-remplissage-numero-$i; i=$((i+1)); done; echo 'Authentication required'", markers: ["Authentication required"])
        XCTAssertNil(r.abortedOn)
    }

    func testTerminateAllStopsRegisteredProcesses() async throws {
        let task = Task { try await self.sh("sleep 30") }
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertGreaterThan(ProcessRegistry.runningCount, 0)
        ProcessRegistry.terminateAll(grace: 3)
        let r = try await task.value
        XCTAssertNotEqual(r.exitCode, 0)
        XCTAssertEqual(ProcessRegistry.runningCount, 0)
    }
}
