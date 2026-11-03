#if os(macOS)
import SwiftUI

struct TaskDeadlinePicker: View {
    let dueDate: String?
    let accent: Color
    let onSave: (Date?) -> Void
    let onCancel: () -> Void

    @State private var draft: Date
    @State private var visibleMonth: Date
    @State private var hoveredDay: Date?
    @FocusState private var focusedDay: Date?

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = .current
        calendar.firstWeekday = Calendar.current.firstWeekday
        return calendar
    }

    init(dueDate: String?, accent: Color, onSave: @escaping (Date?) -> Void, onCancel: @escaping () -> Void) {
        self.dueDate = dueDate
        self.accent = accent
        self.onSave = onSave
        self.onCancel = onCancel
        let date = TaskDeadline.date(for: dueDate) ?? .now
        _draft = State(initialValue: date)
        _visibleMonth = State(initialValue: date)
    }

    private var days: [Date] {
        guard let start = calendar.dateInterval(of: .month, for: visibleMonth)?.start else { return [] }
        let offset = (calendar.component(.weekday, from: start) - calendar.firstWeekday + 7) % 7
        return (0..<42).compactMap { calendar.date(byAdding: .day, value: $0 - offset, to: start) }
    }

    private var weekdayLabels: [String] {
        let labels = calendar.shortStandaloneWeekdaySymbols
        return (0..<7).map { labels[($0 + calendar.firstWeekday - 1) % 7] }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Deadline")
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                    Text(draft.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).year()))
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "calendar")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(accent)
                    .frame(width: 36, height: 36)
                    .background(accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
            }

            HStack(spacing: 6) {
                quickChoice("Today", daysFromNow: 0)
                quickChoice("Tomorrow", daysFromNow: 1)
                quickChoice("In a week", daysFromNow: 7)
            }

            calendarGrid

            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 1)

            HStack(spacing: 8) {
                if dueDate != nil {
                    Button { onSave(nil) } label: {
                        Label("Clear", systemImage: "calendar.badge.minus")
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Remove deadline")
                }
                Spacer(minLength: 8)
                Button("Cancel", action: onCancel)
                    .buttonStyle(DeadlineActionStyle(accent: nil))
                    .keyboardShortcut(.cancelAction)
                Button("Save") { onSave(draft) }
                    .buttonStyle(DeadlineActionStyle(accent: accent))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 320)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            focusedDay = calendar.startOfDay(for: draft)
        }
    }

    private var calendarGrid: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                Text(visibleMonth.formatted(.dateTime.month(.wide).year()))
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                Spacer()
                monthButton("chevron.left", label: "Previous month", offset: -1)
                monthButton("chevron.right", label: "Next month", offset: 1)
            }
            .padding(.bottom, 4)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: 7), spacing: 3) {
                ForEach(Array(weekdayLabels.enumerated()), id: \.offset) { _, label in
                    Text(label.uppercased())
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.primary.opacity(0.35))
                        .frame(height: 20)
                }
                ForEach(days, id: \.self) { date in
                    dayButton(date)
                }
            }
            .onMoveCommand { direction in
                guard let focusedDay else { return }
                let offset: Int
                switch direction {
                case .left: offset = -1
                case .right: offset = 1
                case .up: offset = -7
                case .down: offset = 7
                @unknown default: return
                }
                if let date = calendar.date(byAdding: .day, value: offset, to: focusedDay) {
                    select(date)
                    self.focusedDay = date
                }
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        }
    }

    private func quickChoice(_ title: String, daysFromNow offset: Int) -> some View {
        let date = calendar.date(byAdding: .day, value: offset, to: .now) ?? .now
        let isSelected = calendar.isDate(date, inSameDayAs: draft)
        return Button { select(date) } label: {
            Text(title)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.primary.opacity(isSelected ? 0.95 : 0.58))
                .frame(maxWidth: .infinity)
                .frame(height: 28)
                .background(isSelected ? accent.opacity(0.12) : Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 7))
                .overlay {
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(isSelected ? accent.opacity(0.3) : Color.primary.opacity(0.06), lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func monthButton(_ image: String, label: String, offset: Int) -> some View {
        Button {
            guard let start = calendar.dateInterval(of: .month, for: visibleMonth)?.start,
                  let month = calendar.date(byAdding: .month, value: offset, to: start) else { return }
            visibleMonth = month
        } label: {
            Image(systemName: image)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.primary.opacity(0.58))
                .frame(width: 26, height: 26)
                .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .help(label)
    }

    private func dayButton(_ date: Date) -> some View {
        let isSelected = calendar.isDate(date, inSameDayAs: draft)
        let isCurrentMonth = calendar.isDate(date, equalTo: visibleMonth, toGranularity: .month)
        let isToday = calendar.isDateInToday(date)
        let isFocused = focusedDay == date
        return Button { select(date) } label: {
            Text("\(calendar.component(.day, from: date))")
                .font(.system(size: 12, weight: isSelected || isToday ? .semibold : .medium, design: .rounded))
                .foregroundStyle(isSelected ? Color.black : Color.primary.opacity(isCurrentMonth ? 0.88 : 0.25))
                .frame(maxWidth: .infinity)
                .frame(height: 30)
                .background(isSelected ? accent : Color.primary.opacity(hoveredDay == date ? 0.07 : 0), in: RoundedRectangle(cornerRadius: 7))
                .overlay {
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(accent.opacity(isFocused ? 0.8 : isToday && !isSelected ? 0.4 : 0), lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .focusable()
        .focused($focusedDay, equals: date)
        .focusEffectDisabled()
        .onHover { isHovered in
            if isHovered {
                hoveredDay = date
            } else if hoveredDay == date {
                hoveredDay = nil
            }
        }
        .accessibilityLabel(date.formatted(.dateTime.weekday(.wide).day().month(.wide).year()))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func select(_ date: Date) {
        draft = calendar.startOfDay(for: date)
        visibleMonth = draft
        focusedDay = draft
    }
}

private struct DeadlineActionStyle: ButtonStyle {
    let accent: Color?

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(accent == nil ? Color.primary.opacity(0.65) : .black)
            .padding(.horizontal, 14)
            .frame(height: 30)
            .background(accent ?? Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}
#endif
