import Foundation
import SwiftUI

struct TaskItem: Identifiable, Codable, Hashable {
    let id: UUID
    var title: String
    let createdAt: Date
    var isCompleted: Bool
    var completedAt: Date?

    init(
        id: UUID = UUID(),
        title: String,
        createdAt: Date = .now,
        isCompleted: Bool = false,
        completedAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.isCompleted = isCompleted
        self.completedAt = completedAt
    }
}

struct TaskBoard: Identifiable, Codable, Hashable {
    let id: UUID
    var title: String
    var themeID: BoardTheme.ID
    let createdAt: Date
    var isExpanded: Bool
    var tasks: [TaskItem]

    init(
        id: UUID = UUID(),
        title: String,
        themeID: BoardTheme.ID = BoardTheme.defaultTheme.id,
        createdAt: Date = .now,
        isExpanded: Bool = true,
        tasks: [TaskItem] = []
    ) {
        self.id = id
        self.title = title
        self.themeID = themeID
        self.createdAt = createdAt
        self.isExpanded = isExpanded
        self.tasks = tasks
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
        case createdAt
        case isExpanded
        case tasks
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        themeID = try container.decodeIfPresent(BoardTheme.ID.self, forKey: .themeID) ?? BoardTheme.defaultTheme.id
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? .now
        isExpanded = try container.decodeIfPresent(Bool.self, forKey: .isExpanded) ?? true
        tasks = try container.decodeIfPresent([TaskItem].self, forKey: .tasks) ?? []
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(themeID, forKey: .themeID)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(isExpanded, forKey: .isExpanded)
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
