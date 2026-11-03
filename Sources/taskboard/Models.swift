import Foundation
import SwiftUI

enum TaskStatus: String, Codable, Hashable, CaseIterable, Identifiable {
    case todo
    case running
    case done

    var id: Self { self }
}

struct TaskItem: Identifiable, Codable, Hashable {
    let id: UUID
    var title: String
    let createdAt: Date
    var isCompleted: Bool
    var statusOverride: TaskStatus?
    var completedAt: Date?
    var attachments: [TaskAttachment]
    var plannedFor: String?
    var todayOrder: Int?
    var dueDate: String?

    init(
        id: UUID = UUID(),
        title: String,
        createdAt: Date = .now,
        isCompleted: Bool = false,
        statusOverride: TaskStatus? = nil,
        completedAt: Date? = nil,
        attachments: [TaskAttachment] = [],
        plannedFor: String? = nil,
        todayOrder: Int? = nil,
        dueDate: String? = nil
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.isCompleted = isCompleted
        self.statusOverride = statusOverride
        self.completedAt = completedAt
        self.attachments = attachments
        self.plannedFor = plannedFor
        self.todayOrder = todayOrder
        self.dueDate = dueDate
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, createdAt, isCompleted, statusOverride, isManuallyRunning, completedAt, attachments, plannedFor, todayOrder, dueDate
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        isCompleted = try container.decode(Bool.self, forKey: .isCompleted)
        statusOverride = try container.decodeIfPresent(TaskStatus.self, forKey: .statusOverride)
        if statusOverride == nil,
           try container.decodeIfPresent(Bool.self, forKey: .isManuallyRunning) == true {
            statusOverride = .running
        }
        completedAt = try container.decodeIfPresent(Date.self, forKey: .completedAt)
        plannedFor = try container.decodeIfPresent(String.self, forKey: .plannedFor)
        todayOrder = try container.decodeIfPresent(Int.self, forKey: .todayOrder)
        dueDate = try container.decodeIfPresent(String.self, forKey: .dueDate)
        attachments = try container.decodeIfPresent([TaskAttachment].self, forKey: .attachments) ?? []
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(isCompleted, forKey: .isCompleted)
        try container.encodeIfPresent(statusOverride, forKey: .statusOverride)
        try container.encodeIfPresent(completedAt, forKey: .completedAt)
        try container.encode(attachments, forKey: .attachments)
        try container.encodeIfPresent(plannedFor, forKey: .plannedFor)
        try container.encodeIfPresent(todayOrder, forKey: .todayOrder)
        try container.encodeIfPresent(dueDate, forKey: .dueDate)
    }
}

/// Deadlines are calendar dates, independent of time zones and Today selection.
enum TaskDeadline {
    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar
    }

    static func key(for date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }

    static func date(for key: String?) -> Date? {
        guard let key, key.count == 10 else { return nil }
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, parts[0] > 0,
              let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])),
              Self.key(for: date) == key else { return nil }
        return date
    }

    static func isOverdue(_ dueDate: String?, on today: Date = .now) -> Bool {
        guard let dueDate, date(for: dueDate) != nil else { return false }
        return dueDate < key(for: today)
    }

    static func label(for dueDate: String?, relativeTo today: Date = .now) -> String? {
        guard let dueDate, let date = date(for: dueDate) else { return nil }
        if dueDate == key(for: today) { return "Due today" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: today), dueDate == key(for: tomorrow) {
            return "Due tomorrow"
        }
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: today)
        let formatted = sameYear
            ? date.formatted(.dateTime.day().month(.abbreviated))
            : date.formatted(.dateTime.day().month(.abbreviated).year())
        return "\(isOverdue(dueDate, on: today) ? "Overdue" : "Due") · \(formatted)"
    }
}

struct TaskAttachment: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let fileName: String
    let path: String

    init(id: UUID = UUID(), fileName: String, path: String) {
        self.id = id
        self.fileName = fileName
        self.path = path
    }
}

struct TaskBoard: Identifiable, Codable, Hashable {
    let id: UUID
    var title: String
    var themeID: BoardTheme.ID
    var folderPath: String
    var t3ProjectID: String?
    var t3ProjectTitle: String?
    let createdAt: Date
    var isExpanded: Bool
    var isPinned: Bool
    var tasks: [TaskItem]

    init(
        id: UUID = UUID(),
        title: String,
        themeID: BoardTheme.ID = BoardTheme.defaultTheme.id,
        folderPath: String = "",
        t3ProjectID: String? = nil,
        t3ProjectTitle: String? = nil,
        createdAt: Date = .now,
        isExpanded: Bool = true,
        isPinned: Bool = false,
        tasks: [TaskItem] = []
    ) {
        self.id = id
        self.title = title
        self.themeID = themeID
        self.folderPath = folderPath
        self.t3ProjectID = t3ProjectID
        self.t3ProjectTitle = t3ProjectTitle
        self.createdAt = createdAt
        self.isExpanded = isExpanded
        self.isPinned = isPinned
        self.tasks = tasks
    }

    var isTodayBoard: Bool {
        title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "today"
    }

    var theme: BoardTheme {
        BoardTheme(id: themeID)
    }

    var openTasks: [TaskItem] {
        tasks.filter { !$0.isCompleted }
    }

    var completedCount: Int {
        tasks.count - openTasks.count
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case themeID
        case folderPath
        case t3ProjectID
        case t3ProjectTitle
        case createdAt
        case isExpanded
        case isPinned
        case tasks
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        themeID = try container.decodeIfPresent(BoardTheme.ID.self, forKey: .themeID) ?? BoardTheme.defaultTheme.id
        folderPath = try container.decodeIfPresent(String.self, forKey: .folderPath) ?? ""
        t3ProjectID = try container.decodeIfPresent(String.self, forKey: .t3ProjectID)
        t3ProjectTitle = try container.decodeIfPresent(String.self, forKey: .t3ProjectTitle)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? .now
        isExpanded = try container.decodeIfPresent(Bool.self, forKey: .isExpanded) ?? true
        isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        tasks = try container.decodeIfPresent([TaskItem].self, forKey: .tasks) ?? []
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(themeID, forKey: .themeID)
        try container.encode(folderPath, forKey: .folderPath)
        try container.encodeIfPresent(t3ProjectID, forKey: .t3ProjectID)
        try container.encodeIfPresent(t3ProjectTitle, forKey: .t3ProjectTitle)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(isExpanded, forKey: .isExpanded)
        try container.encode(isPinned, forKey: .isPinned)
        try container.encode(tasks, forKey: .tasks)
    }
}

struct BoardTheme: Identifiable, Codable, Hashable {
    typealias ID = String

    let id: ID
    let name: String
    let startColorHex: String
    let endColorHex: String
    let accentHex: String

    static let all: [BoardTheme] = [
        .init(id: "cobalt", name: "Cobalt", startColorHex: "172554", endColorHex: "1D4ED8", accentHex: "60A5FA"),
        .init(id: "mint", name: "Mint", startColorHex: "052E2B", endColorHex: "0F766E", accentHex: "5EEAD4"),
        .init(id: "sunrise", name: "Sunrise", startColorHex: "431407", endColorHex: "C2410C", accentHex: "FDBA74"),
        .init(id: "rose", name: "Rose", startColorHex: "4A0D22", endColorHex: "BE123C", accentHex: "FDA4AF"),
        .init(id: "forest", name: "Forest", startColorHex: "0B1F17", endColorHex: "166534", accentHex: "86EFAC"),
        .init(id: "slate", name: "Slate", startColorHex: "111827", endColorHex: "334155", accentHex: "CBD5E1"),
    ]

    static let defaultTheme = BoardTheme.all[0]

    init(id: ID, name: String, startColorHex: String, endColorHex: String, accentHex: String) {
        self.id = id
        self.name = name
        self.startColorHex = startColorHex
        self.endColorHex = endColorHex
        self.accentHex = accentHex
    }

    init(id: ID) {
        self = Self.all.first(where: { $0.id == id }) ?? Self.defaultTheme
    }

    static func random(excluding currentIDs: Set<ID> = []) -> BoardTheme {
        let filtered = all.filter { !currentIDs.contains($0.id) }
        return filtered.randomElement() ?? all.randomElement() ?? defaultTheme
    }

    var gradient: LinearGradient {
        LinearGradient(
            colors: [Color(hex: startColorHex), Color(hex: endColorHex)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    var accentColor: Color {
        Color(hex: accentHex)
    }

    var mutedBorder: Color {
        accentColor.opacity(0.14)
    }
}

extension Color {
    init(hex: String) {
        let sanitized = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int = UInt64()
        Scanner(string: sanitized).scanHexInt64(&int)

        let a, r, g, b: UInt64
        switch sanitized.count {
        case 8:
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        }

        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}
