import Foundation
import XCTest
@testable import taskboard

final class T3CodeClientTests: XCTestCase {
    func testParsesFavoritesInOrderWithoutDuplicates() throws {
        let settings = Data("""
        {"favorites": [
          {"provider": "codex", "model": "gpt-6-astra"},
          {"provider": "claudeAgent", "model": "claude-opus-5-5"},
          {"provider": "codex", "model": "gpt-6-astra"}
        ]}
        """.utf8)

        XCTAssertEqual(T3Parsing.favorites(fromSettings: settings), [
            T3FavoriteModel(instanceID: "codex", model: "gpt-6-astra"),
            T3FavoriteModel(instanceID: "claudeAgent", model: "claude-opus-5-5"),
        ])
    }

    func testParsesFavoritesNestedUnderClientSettings() {
        let clientSettings = Data("""
        {"settings": {"favorites": [{"provider": "claudeAgent", "model": "claude-sonnet-5-5"}]}}
        """.utf8)

        XCTAssertEqual(T3Parsing.favorites(fromSettings: clientSettings), [
            T3FavoriteModel(instanceID: "claudeAgent", model: "claude-sonnet-5-5"),
        ])
    }

    func testJoinsFavoritesWithCatalogLabelsAndDropsMissingProviders() {
        let favorites = [
            T3FavoriteModel(instanceID: "codex", model: "gpt-6-astra"),
            T3FavoriteModel(instanceID: "codex", model: "custom-model"),
            T3FavoriteModel(instanceID: "removed", model: "anything"),
        ]
        let capabilities: [String: Any] = ["providers": [[
            "providerInstanceId": "codex",
            "displayName": "Codex",
            "models": [["id": "gpt-6-astra", "label": "GPT-6-Astra"]],
        ]]]

        let options = T3Parsing.modelOptions(
            favorites: favorites,
            capabilities: capabilities,
            accents: ["codex": "#2563eb"]
        )

        XCTAssertEqual(options.map(\.id), ["codex/gpt-6-astra", "codex/custom-model"])
        XCTAssertEqual(options.first?.modelLabel, "GPT-6-Astra")
        XCTAssertEqual(options.first?.providerName, "Codex")
        XCTAssertEqual(options.first?.accentHex, "#2563eb")
        XCTAssertEqual(options.last?.modelLabel, "custom-model")
    }

    func testParsesProjectsSkippingDeletedOnes() {
        let payload: [String: Any] = ["projects": [
            ["id": "p1", "title": "taskboard", "workspaceRoot": "/repo", "deletedAt": NSNull()],
            ["id": "p2", "title": "old", "workspaceRoot": "/old", "deletedAt": "2026-01-01T00:00:00Z"],
        ]]

        XCTAssertEqual(T3Parsing.projects(from: payload), [
            T3Project(id: "p1", title: "taskboard", workspaceRoot: "/repo"),
        ])
    }

    func testParsesThreadState() {
        let payload: [String: Any] = ["thread": [
            "threadId": "t1",
            "status": "completed",
            "settled": true,
            "archived": false,
            "pendingRequestCount": 0,
        ]]

        XCTAssertEqual(
            T3Parsing.threadState(from: payload),
            T3ThreadState(threadID: "t1", status: "completed", settled: true, archived: false, pendingRequestCount: 0)
        )
    }

    func testExtractsPairingCodeFromNoisyCLIOutput() {
        let output = """
        [1018/170204.599743:ERROR:electron] noise
        {
          "id": "abc",
          "credential": "R4V83UC88NSF",
          "label": "Taskboard"
        }
        trailing log line
        """

        XCTAssertEqual(T3Parsing.pairingCode(fromCLIOutput: output), "R4V83UC88NSF")
    }

    func testExtractsAuthorizationCodeFromRedirect() {
        let redirect = "http://127.0.0.1:47123/taskboard/callback?code=abc_123&state=s&iss=http%3A%2F%2F127.0.0.1%3A3773"
        XCTAssertEqual(T3Parsing.authorizationCode(fromRedirect: redirect), "abc_123")
    }

    func testPKCEChallengeMatchesRFC7636Example() {
        XCTAssertEqual(
            T3Parsing.pkceChallenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"),
            "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
        )
    }

    func testReadsJSONRPCMessageFromEventStream() {
        let body = Data("event: message\ndata: {\"jsonrpc\":\"2.0\",\"id\":7,\"result\":{}}\n\n".utf8)
        let message = T3Parsing.rpcMessage(from: body, contentType: "text/event-stream", id: 7)
        XCTAssertEqual(message?["id"] as? Int, 7)
    }

    func testToolErrorsSurfaceTheirMessage() {
        let message: [String: Any] = ["result": [
            "isError": true,
            "content": [["type": "text", "text": "{\"code\":\"not_found\",\"message\":\"Thread not found.\"}"]],
        ]]

        XCTAssertThrowsError(try T3Parsing.toolResult(from: message)) { error in
            XCTAssertEqual(error as? T3CodeError, .toolFailed("Thread not found."))
        }
    }

    func testThreadURLUsesAppDeepLinkFormat() throws {
        guard let environmentID = T3Environment.environmentID() else {
            throw XCTSkip("T3 Code is not installed on this machine.")
        }
        XCTAssertEqual(
            T3Environment.threadURL("thread-1")?.absoluteString,
            "t3code://threads/\(environmentID)/thread-1"
        )
    }

    func testThreadURLEncodesLaunchedThreadIDsLikeT3() throws {
        guard let environmentID = T3Environment.environmentID() else {
            throw XCTSkip("T3 Code is not installed on this machine.")
        }
        XCTAssertEqual(
            T3Environment.threadURL("mcp:68b4ba1d")?.absoluteString,
            "t3code://threads/\(environmentID)/mcp%3A68b4ba1d"
        )
        XCTAssertEqual(T3Environment.threadLink("mcp:68b4ba1d"), "<t3-thread://v2/\(environmentID)/mcp:68b4ba1d>")
    }

    func testLaunchReceiptKeepsT3Link() {
        let receipt = T3Parsing.launchReceipt(from: [
            "threadId": "mcp:1", "status": "starting", "link": "<t3-thread://v2/env/mcp:1>",
        ])
        XCTAssertEqual(receipt?.link, "<t3-thread://v2/env/mcp:1>")
    }

    func testThreadTitleUsesFirstLineLikeTheT3CLI() {
        XCTAssertEqual(T3Parsing.threadTitle(from: "  Fix login\nmore detail"), "Fix login")
        let long = String(repeating: "a", count: 120)
        XCTAssertEqual(T3Parsing.threadTitle(from: long).count, 80)
    }
}
