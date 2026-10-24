import XCTest
@testable import MCPGeminiKit

private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_000_000)
    var date: Date { lock.lock(); defer { lock.unlock() }; return current }
    func advance(_ seconds: TimeInterval) { lock.lock(); current += seconds; lock.unlock() }
}

final class SessionStoreTests: XCTestCase {
    func testTurnLimitStopsTheLoop() async throws {
        let store = SessionStore(maxTurns: 3, maxCalls: 100)
        var id = ""
        for turn in 1...3 {
            let session = try await store.begin(sessionId: turn == 1 ? nil : id)
            id = session.id
            XCTAssertEqual(session.turn, turn)
            await store.finish(id: id, prompt: "q\(turn)", response: "r\(turn)", conversationId: "c")
        }
        do {
            _ = try await store.begin(sessionId: id)
            XCTFail("la 4e demande aurait dû être refusée")
        } catch let error as SessionError {
            XCTAssertEqual(error, .turnLimit(id: id, max: 3))
        }
    }

    func testFailedTurnDoesNotCount() async throws {
        let store = SessionStore(maxTurns: 1, maxCalls: 100)
        let first = try await store.begin(sessionId: nil)
        await store.abort(id: first.id)
        let second = try await store.begin(sessionId: first.id)
        XCTAssertEqual(second.turn, 1)
        await store.finish(id: second.id, prompt: "q", response: "r", conversationId: nil)
        let turns = await store.turns(of: first.id)
        XCTAssertEqual(turns, 1)
    }

    func testBusySessionIsRefused() async throws {
        let store = SessionStore(maxTurns: 5, maxCalls: 100)
        let session = try await store.begin(sessionId: nil)
        do {
            _ = try await store.begin(sessionId: session.id)
            XCTFail("session occupée")
        } catch let error as SessionError {
            XCTAssertEqual(error, .busy(id: session.id))
        }
    }

    func testUnknownSession() async {
        let store = SessionStore(maxTurns: 5, maxCalls: 100)
        do {
            _ = try await store.begin(sessionId: "zzz")
            XCTFail()
        } catch let error as SessionError {
            XCTAssertEqual(error, .unknown(id: "zzz"))
        } catch { XCTFail("\(error)") }
    }

    func testHistoryAndConversationIdAreKept() async throws {
        let store = SessionStore(maxTurns: 5, maxCalls: 100)
        let first = try await store.begin(sessionId: nil)
        XCTAssertNil(first.conversationId)
        await store.finish(id: first.id, prompt: "q1", response: "r1", conversationId: "conv")
        let second = try await store.begin(sessionId: first.id)
        XCTAssertEqual(second.conversationId, "conv")
        XCTAssertEqual(second.history, [Exchange(prompt: "q1", response: "r1")])
    }

    func testRateLimitUsesRollingWindow() async throws {
        let clock = Clock()
        let store = SessionStore(maxTurns: 5, maxCalls: 2, window: 600, now: { clock.date })
        for _ in 0..<2 {
            let s = try await store.begin(sessionId: nil)
            await store.abort(id: s.id)
        }
        do {
            _ = try await store.begin(sessionId: nil)
            XCTFail("limite d'appels")
        } catch let error as SessionError {
            XCTAssertEqual(error, .rateLimited(max: 2))
        }
        clock.advance(601)
        _ = try await store.begin(sessionId: nil)
    }

    func testIdleSessionsExpire() async throws {
        let clock = Clock()
        let store = SessionStore(maxTurns: 5, maxCalls: 100, idleLimit: 100, now: { clock.date })
        let s = try await store.begin(sessionId: nil)
        await store.finish(id: s.id, prompt: "q", response: "r", conversationId: nil)
        clock.advance(101)
        do {
            _ = try await store.begin(sessionId: s.id)
            XCTFail("session expirée")
        } catch let error as SessionError {
            XCTAssertEqual(error, .unknown(id: s.id))
        }
    }

    func testResetForgetsSession() async throws {
        let store = SessionStore(maxTurns: 5, maxCalls: 100)
        let s = try await store.begin(sessionId: nil)
        await store.finish(id: s.id, prompt: "q", response: "r", conversationId: nil)
        let first = await store.reset(id: s.id)
        let second = await store.reset(id: s.id)
        XCTAssertTrue(first)
        XCTAssertFalse(second)
    }

    func testSessionCountIsBounded() async throws {
        let clock = Clock()
        let store = SessionStore(maxTurns: 5, maxCalls: 1000, now: { clock.date })
        for _ in 0..<40 {
            let s = try await store.begin(sessionId: nil)
            await store.abort(id: s.id)
            clock.advance(1)
        }
        let count = await store.count
        XCTAssertLessThanOrEqual(count, 20)
    }

    func testResumingASessionNeverEvictsIt() async throws {
        let clock = Clock()
        let store = SessionStore(maxTurns: 50, maxCalls: 1000, now: { clock.date })
        var ids: [String] = []
        for _ in 0..<20 {
            let s = try await store.begin(sessionId: nil)
            await store.finish(id: s.id, prompt: "q", response: "r", conversationId: nil)
            ids.append(s.id)
            clock.advance(1)
        }
        let resumed = try await store.begin(sessionId: ids[0])
        XCTAssertEqual(resumed.id, ids[0])
        await store.abort(id: ids[0])
    }

    func testNoteCallCountsInTheRateLimit() async throws {
        let store = SessionStore(maxTurns: 5, maxCalls: 2)
        try await store.noteCall()
        try await store.noteCall()
        do {
            try await store.noteCall()
            XCTFail("limite d'appels")
        } catch let error as SessionError {
            XCTAssertEqual(error, .rateLimited(max: 2))
        }
    }
}
