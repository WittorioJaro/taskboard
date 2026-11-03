import Foundation
import XCTest
@testable import taskboard

@MainActor
final class FirebaseSyncServiceTests: XCTestCase {
    private let databaseURL = URL(string: "https://example.invalid")!
    private let session = FirebaseAuthSession(idToken: "expired", refreshToken: "refresh+token&with=padding", userID: "owner")

    func testExpiredTokenRefreshEncodesFormAndRetriesRequest() async throws {
        var requests: [URLRequest] = []
        var savedSession: FirebaseAuthSession?
        let service = FirebaseSyncService(databaseURL: databaseURL, apiKey: "test-key", session: session, requestData: { request in
            requests.append(request)
            if request.url?.host == "securetoken.googleapis.com" {
                XCTAssertEqual(String(data: request.httpBody!, encoding: .utf8), "grant_type=refresh_token&refresh_token=refresh%2Btoken%26with%3Dpadding")
                return self.response(request, json: "{\"id_token\":\"new-id-token\",\"refresh_token\":\"new-refresh\",\"user_id\":\"owner\"}")
            }
            let token = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first?.value
            return self.response(request, status: token == "expired" ? 401 : 200, json: "null")
        }, persistSession: { savedSession = $0 })

        let remote = try await service.fetchSnapshot()

        XCTAssertNil(remote)
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(savedSession?.idToken, "new-id-token")
        service.stop()
    }

    func testFailedUploadRetriesWithoutAnotherEdit() async throws {
        let failed = expectation(description: "upload failure reported")
        let recovered = expectation(description: "upload recovered")
        var attempts = 0
        let service = makeService { request in
            attempts += 1
            if attempts == 1 { throw URLError(.notConnectedToInternet) }
            return self.response(request, json: "null")
        }
        defer { service.stop() }

        service.scheduleSave(snapshot: snapshot("Latest")) { result in
            switch result {
            case .failure: failed.fulfill()
            case .success: recovered.fulfill()
            }
        }
        await fulfillment(of: [failed, recovered], timeout: 2)
        XCTAssertEqual(attempts, 2)
        XCTAssertFalse(service.hasPendingSave)
    }

    func testRevokedSessionKeepsLatestUploadUntilSignInWithoutRepeatingRequests() async throws {
        let file = try temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        var attempts = 0
        let service = makeService(pendingUploadURL: file) { request in
            attempts += 1
            if request.url?.host == "securetoken.googleapis.com" {
                return self.response(request, status: 400, json: "{\"error\":{\"message\":\"TOKEN_EXPIRED\"}}")
            }
            return self.response(request, status: 401, json: "{\"error\":\"Permission denied\"}")
        }
        defer { service.stop() }
        do { try await service.save(snapshot: snapshot("First")); XCTFail("Expected sign-in error") } catch {}
        XCTAssertTrue(service.requiresSignIn)
        do { try await service.save(snapshot: snapshot("Latest")); XCTFail("Expected sign-in error") } catch {}
        XCTAssertEqual(attempts, 2)
        XCTAssertTrue(service.hasPendingSave)
        let pending = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        let saved = pending["snapshot"] as! [String: Any]
        XCTAssertEqual((saved["boards"] as! [[String: Any]])[0]["title"] as? String, "Latest")
    }

    func testNewerSnapshotSurvivesFailureOfInFlightUpload() async throws {
        let started = expectation(description: "first upload started")
        let recovered = expectation(description: "latest snapshot uploaded")
        var firstRequest: CheckedContinuation<(Data, URLResponse), Error>?
        var titles: [String] = []
        let service = makeService { request in
            titles.append(try self.uploadedSnapshot(request).boards[0].title)
            if titles.count == 1 {
                started.fulfill()
                return try await withCheckedThrowingContinuation { firstRequest = $0 }
            }
            return self.response(request, json: "null")
        }
        defer { service.stop() }
        service.scheduleSave(snapshot: snapshot("Older")) { _ in }
        await fulfillment(of: [started], timeout: 2)
        service.scheduleSave(snapshot: snapshot("Newest")) { result in
            if case .success = result { recovered.fulfill() }
        }
        firstRequest?.resume(throwing: URLError(.networkConnectionLost))
        await fulfillment(of: [recovered], timeout: 2)
        XCTAssertEqual(titles, ["Older", "Newest"])
    }

    func testPendingUploadSurvivesRestartAndClearsOnlyAfterSuccess() async throws {
        let file = try temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let failed = makeService(pendingUploadURL: file) { _ in throw URLError(.notConnectedToInternet) }
        do {
            try await failed.save(snapshot: snapshot("Offline changes"))
            XCTFail("Expected an offline failure")
        } catch {}
        failed.stop()
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))

        var uploaded: TaskBoardSnapshot?
        let recovered = makeService(pendingUploadURL: file) { request in
            uploaded = try self.uploadedSnapshot(request)
            return self.response(request, json: "null")
        }
        defer { recovered.stop() }
        XCTAssertTrue(recovered.hasPendingSave)
        try await recovered.save(snapshot: snapshot("Latest local disk"))
        XCTAssertEqual(uploaded?.boards[0].title, "Latest local disk")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testPendingUploadIsNotReusedForAnotherAccount() throws {
        let file = try temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let first = FirebaseSyncService(databaseURL: databaseURL, apiKey: "key", session: session, pendingUploadURL: file, debounceDelay: .seconds(60))
        first.scheduleSave(snapshot: snapshot("Private to owner")) { _ in }
        first.stop()
        let other = FirebaseSyncService(databaseURL: databaseURL, apiKey: "key", session: .init(idToken: "other", refreshToken: "other", userID: "another-owner"), pendingUploadURL: file)
        defer { other.stop() }
        XCTAssertFalse(other.hasPendingSave)
    }

    func testEditsStagedWithoutSessionAreRecoveredOnlyForMatchingEmail() throws {
        let file = try temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        try FirebaseSyncService.stagePendingUpload(snapshot("Offline Mac"), databaseURL: databaseURL, email: "owner@example.invalid", at: file)
        let matching = FirebaseSyncService(databaseURL: databaseURL, apiKey: "key", session: session, pendingUploadURL: file, accountEmail: "owner@example.invalid")
        let different = FirebaseSyncService(databaseURL: databaseURL, apiKey: "key", session: session, pendingUploadURL: file, accountEmail: "someone-else@example.invalid")
        defer { matching.stop(); different.stop() }
        XCTAssertTrue(matching.hasPendingSave)
        XCTAssertFalse(different.hasPendingSave)
    }

    func testStartupUploadsPendingMacDataBeforeReadingStaleCloud() async throws {
        let file = try temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let local = snapshot("Current Mac")
        let storage = file.deletingLastPathComponent().appendingPathComponent("boards.json")
        try JSONEncoder().encode(local).write(to: storage)
        let beforeRestart = FirebaseSyncService(databaseURL: databaseURL, apiKey: "key", session: session, pendingUploadURL: file, debounceDelay: .seconds(60))
        beforeRestart.scheduleSave(snapshot: local) { _ in }
        beforeRestart.stop()
        var methods: [String] = []
        let service = makeService(pendingUploadURL: file) { request in
            methods.append(request.httpMethod!)
            XCTAssertEqual(try self.uploadedSnapshot(request).boards, local.boards)
            return self.response(request, json: "null")
        }
        defer { service.stop() }
        let store = TaskBoardStore(enablesCloudSync: false, storageURL: storage, watchesExternalEdits: false)

        await store.startFirebaseSync(service, enablesRealtime: false)

        XCTAssertEqual(methods, ["PUT"])
        XCTAssertEqual(store.boards, local.boards)
        XCTAssertEqual(store.syncStatus, .synced)
    }

    func testStartupUploadsRecoveredPendingContentNotStaleDiskCopy() async throws {
        let file = try temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let disk = snapshot("Mac")
        let storage = file.deletingLastPathComponent().appendingPathComponent("boards.json")
        try JSONEncoder().encode(disk).write(to: storage)
        // The pending file holds a queue rebased onto a remote addition that never reached boards.json.
        var rebased = disk
        rebased.boards[0].tasks.append(TaskItem(title: "Added remotely"))
        let beforeRestart = FirebaseSyncService(databaseURL: databaseURL, apiKey: "key", session: session, pendingUploadURL: file, debounceDelay: .seconds(60))
        beforeRestart.scheduleSave(snapshot: rebased) { _ in }
        beforeRestart.stop()
        var uploaded: TaskBoardSnapshot?
        let service = makeService(pendingUploadURL: file) { request in
            uploaded = try self.uploadedSnapshot(request)
            return self.response(request, json: "null")
        }
        defer { service.stop() }
        let store = TaskBoardStore(enablesCloudSync: false, storageURL: storage, watchesExternalEdits: false)

        await store.startFirebaseSync(service, enablesRealtime: false)

        XCTAssertEqual(uploaded?.boards[0].tasks.map(\.title), ["Added remotely"])
        XCTAssertEqual(store.boards[0].tasks.map(\.title), ["Added remotely"])
    }

    func testReplacedServiceDoesNotApplyItsStartupFetch() async throws {
        let storage = try temporaryFile()
        defer { try? FileManager.default.removeItem(at: storage.deletingLastPathComponent()) }
        let local = snapshot("Mac")
        try JSONEncoder().encode(local).write(to: storage)
        let fetching = expectation(description: "old startup fetch in flight")
        var release: CheckedContinuation<Void, Never>?
        let stale = snapshot("Stale cloud")
        let old = FirebaseSyncService(databaseURL: databaseURL, apiKey: "key", session: session, requestData: { request in
            await withCheckedContinuation { continuation in
                release = continuation
                fetching.fulfill()
            }
            let data = try JSONSerialization.data(withJSONObject: [
                "payload": JSONSerialization.jsonObject(with: JSONEncoder().encode(stale)), "updatedAt": 1,
            ])
            return self.response(request, data: data)
        })
        let replacement = makeService { request in self.response(request, json: "null") }
        defer { old.stop(); replacement.stop() }
        let store = TaskBoardStore(enablesCloudSync: false, storageURL: storage, watchesExternalEdits: false)

        let oldStartup = Task { await store.startFirebaseSync(old, enablesRealtime: false) }
        await fulfillment(of: [fetching], timeout: 2)
        old.stop() // Reconnect
        await store.startFirebaseSync(replacement, enablesRealtime: false)
        release?.resume()
        await oldStartup.value

        XCTAssertEqual(store.boards.map(\.title), ["Mac"])
        XCTAssertEqual(store.syncStatus, .synced)
    }

    func testStoppedServiceIgnoresInFlightUploadCompletion() async throws {
        let file = try temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let uploading = expectation(description: "upload in flight")
        var release: CheckedContinuation<Void, Never>?
        let service = makeService(pendingUploadURL: file) { request in
            await withCheckedContinuation { continuation in
                release = continuation
                uploading.fulfill()
            }
            return self.response(request, json: "null")
        }
        var savedCallbacks = 0
        service.onSavedSnapshot = { _ in savedCallbacks += 1 }
        service.scheduleSave(snapshot: snapshot("Old service")) { _ in }
        await fulfillment(of: [uploading], timeout: 2)

        service.stop()
        // A replacement service has staged its own pending upload in the shared file.
        try FirebaseSyncService.stagePendingUpload(snapshot("Replacement"), databaseURL: databaseURL, email: "owner@example.invalid", at: file)
        release?.resume()
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(savedCallbacks, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func testLocalEditDuringInitialFetchIsUploadedInsteadOfOverwritten() async throws {
        let storage = try temporaryFile()
        defer { try? FileManager.default.removeItem(at: storage.deletingLastPathComponent()) }
        let local = snapshot("Mac")
        try JSONEncoder().encode(local).write(to: storage)
        let fetching = expectation(description: "initial fetch in progress")
        var fetchRequest: CheckedContinuation<(Data, URLResponse), Error>?
        var initialRequest: URLRequest?
        var uploaded: TaskBoardSnapshot?
        let service = makeService { request in
            if request.httpMethod == "GET" {
                initialRequest = request
                fetching.fulfill()
                return try await withCheckedThrowingContinuation { fetchRequest = $0 }
            }
            uploaded = try self.uploadedSnapshot(request)
            return self.response(request, json: "null")
        }
        defer { service.stop() }
        let store = TaskBoardStore(enablesCloudSync: false, storageURL: storage, watchesExternalEdits: false)
        let startup = Task { await store.startFirebaseSync(service, enablesRealtime: false) }
        await fulfillment(of: [fetching], timeout: 2)
        store.addTask(to: local.boards[0].id, title: "Captured during startup")
        let envelope = try JSONSerialization.data(withJSONObject: ["payload": JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot("Stale cloud"))), "updatedAt": 1])
        fetchRequest?.resume(returning: response(initialRequest!, data: envelope))
        await startup.value
        XCTAssertEqual(store.boards[0].title, "Mac")
        XCTAssertEqual(store.boards[0].tasks.first?.title, "Captured during startup")
        XCTAssertEqual(uploaded?.boards, store.boards)
    }

    func testRemoteAdditionMergedIntoQueuedEditSurvivesLaterEdits() async throws {
        let storage = try temporaryFile()
        defer { try? FileManager.default.removeItem(at: storage.deletingLastPathComponent()) }
        let task = TaskItem(title: "Original")
        let board = TaskBoard(title: "Project", tasks: [task])
        var remote = TaskBoardSnapshot(boards: [board], selectedBoardID: board.id)
        try JSONEncoder().encode(remote).write(to: storage)
        var gates: [CheckedContinuation<Void, Never>] = []
        let putStarted: [XCTestExpectation] = (0..<3).map { expectation(description: "PUT \($0)") }
        var puts = 0
        let service = FirebaseSyncService(databaseURL: databaseURL, apiKey: "key", session: session,
            debounceDelay: .milliseconds(1), requestData: { request in
                if request.httpMethod == "GET" {
                    let data = try JSONSerialization.data(withJSONObject: [
                        "payload": JSONSerialization.jsonObject(with: JSONEncoder().encode(remote)), "updatedAt": 1,
                    ])
                    return self.response(request, data: data)
                }
                let index = puts
                puts += 1
                await withCheckedContinuation { continuation in
                    gates.append(continuation)
                    putStarted[index].fulfill()
                }
                remote = try self.uploadedSnapshot(request)
                return self.response(request, json: "null")
            })
        defer { service.stop() }
        let store = TaskBoardStore(enablesCloudSync: false, storageURL: storage, watchesExternalEdits: false)
        await store.startFirebaseSync(service, enablesRealtime: false)
        remote.boards[0].tasks.append(TaskItem(title: "Added by agent"))

        store.renameTask(taskID: task.id, in: board.id, title: "A")
        await fulfillment(of: [putStarted[0]], timeout: 2)
        store.renameTask(taskID: task.id, in: board.id, title: "B") // queued behind A
        gates.removeFirst().resume()
        await fulfillment(of: [putStarted[1]], timeout: 2)
        _ = store.addTask(to: board.id, title: "C") // made while B uploads
        gates.removeFirst().resume()
        await fulfillment(of: [putStarted[2]], timeout: 2)
        gates.removeFirst().resume()
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(Set(remote.boards[0].tasks.map(\.title)), ["B", "Added by agent", "C"])
        XCTAssertEqual(Set(store.boards[0].tasks.map(\.title)), ["B", "Added by agent", "C"])
    }

    func testConditionalUploadRetriesConflictAndPreservesAgentPlanAndLocalRename() async throws {
        let task = TaskItem(title: "Original")
        let base = TaskBoardSnapshot(boards: [TaskBoard(title: "Project", tasks: [task])])
        var remote = base
        var reads = 0
        var uploads = 0
        var saved: TaskBoardSnapshot?
        let service = FirebaseSyncService(databaseURL: databaseURL, apiKey: "key", session: session,
            requestData: { request in
                if request.httpMethod == "GET" {
                    reads += 1
                    let data = try JSONSerialization.data(withJSONObject: [
                        "payload": JSONSerialization.jsonObject(with: JSONEncoder().encode(remote)), "updatedAt": reads,
                    ])
                    return self.response(request, data: data)
                }
                XCTAssertEqual(request.value(forHTTPHeaderField: "if-match"), "\"version\"")
                uploads += 1
                if uploads == 1 {
                    remote.boards[0].tasks[0].plannedFor = "2026-10-31"
                    remote.boards[0].tasks[0].todayOrder = 0
                    remote.boards[0].tasks.append(TaskItem(title: "Added by agent"))
                    return self.response(request, status: 412, json: "null")
                }
                saved = try self.uploadedSnapshot(request)
                return self.response(request, json: "null")
            })
        defer { service.stop() }
        _ = try await service.fetchSnapshot()
        var local = base
        local.boards[0].tasks[0].title = "Renamed on Mac"
        try await service.save(snapshot: local)
        XCTAssertEqual(uploads, 2)
        XCTAssertEqual(saved?.boards[0].tasks[0].title, "Renamed on Mac")
        XCTAssertEqual(saved?.boards[0].tasks[0].plannedFor, "2026-10-31")
        XCTAssertEqual(saved?.boards[0].tasks[1].title, "Added by agent")
    }

    private func makeService(
        pendingUploadURL: URL? = nil,
        request: @escaping @MainActor (URLRequest) async throws -> (Data, URLResponse)
    ) -> FirebaseSyncService {
        FirebaseSyncService(databaseURL: databaseURL, apiKey: "test-key", session: session, pendingUploadURL: pendingUploadURL, debounceDelay: .milliseconds(1), retryDelay: .milliseconds(10), requestData: { requestValue in
            // Queue tests use an empty cloud; concurrency is exercised separately.
            if requestValue.value(forHTTPHeaderField: "X-Firebase-ETag") == "true" {
                return self.response(requestValue, json: "null")
            }
            return try await request(requestValue)
        })
    }

    private func snapshot(_ title: String) -> TaskBoardSnapshot {
        let board = TaskBoard(title: title)
        return TaskBoardSnapshot(boards: [board], selectedBoardID: board.id)
    }

    private func response(_ request: URLRequest, status: Int = 200, json: String) -> (Data, URLResponse) {
        response(request, status: status, data: Data(json.utf8))
    }

    private func response(_ request: URLRequest, status: Int = 200, data: Data) -> (Data, URLResponse) {
        (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["ETag": "\"version\""])!)
    }

    private func uploadedSnapshot(_ request: URLRequest) throws -> TaskBoardSnapshot {
        struct Envelope: Decodable { let payload: TaskBoardSnapshot }
        return try JSONDecoder().decode(Envelope.self, from: request.httpBody!).payload
    }

    private func temporaryFile() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("pending.json")
    }
}
