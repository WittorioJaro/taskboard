import Foundation
import XCTest
@testable import taskboard

final class TaskItemStatusTests: XCTestCase {
    func testStatusOverrideRoundTrips() throws {
        let task = TaskItem(title: "Ship the redesign", statusOverride: .done)

        let data = try JSONEncoder().encode(task)
        let restored = try JSONDecoder().decode(TaskItem.self, from: data)

        XCTAssertEqual(restored.statusOverride, .done)
    }

    func testLegacyManualRunningFlagMigrates() throws {
        let legacyTask: [String: Any] = [
            "id": UUID().uuidString,
            "title": "Legacy running task",
            "createdAt": 0.0,
            "isCompleted": false,
            "isManuallyRunning": true,
            "attachments": [],
        ]
        let data = try JSONSerialization.data(withJSONObject: legacyTask)

        let restored = try JSONDecoder().decode(TaskItem.self, from: data)

        XCTAssertEqual(restored.statusOverride, .running)
    }
}
