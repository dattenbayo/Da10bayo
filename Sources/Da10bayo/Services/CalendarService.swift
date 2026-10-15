import Foundation
import EventKit
import SwiftUI

/// Ближайшее событие календаря и напоминание за 5 минут до начала.
final class CalendarService: ObservableObject {
    struct EventInfo: Equatable {
        var id: String
        var title: String
        var start: Date
        var end: Date
        var color: Color
        var location: String?

        var timeText: String {
            let minutes = Int(start.timeIntervalSinceNow / 60)
            if start <= Date() { return "Идёт сейчас · до \(Self.time.string(from: end))" }
            if minutes < 60 { return "Через \(max(1, minutes)) мин" }
            return "\(Self.time.string(from: start))–\(Self.time.string(from: end))"
        }

        private static let time: DateFormatter = {
            let f = DateFormatter()
            f.locale = Locale(identifier: "ru_RU")
            f.dateFormat = "HH:mm"
            return f
        }()
    }

    @Published private(set) var nextEvent: EventInfo?
    @Published private(set) var authorized = false

    var onUpcoming: ((EventInfo) -> Void)?

    private let store = EKEventStore()
    private var notified = Set<String>()
    private var timer: Timer?

    func start() {
        let status = EKEventStore.authorizationStatus(for: .event)
        authorized = status == .fullAccess
        if status == .notDetermined && AppSettings.shared.calendarReminders {
            requestAccess()
        } else if authorized {
            refresh()
        }
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            self?.refresh()
        }
        let t = Timer(timeInterval: 30, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func requestAccess() {
        store.requestFullAccessToEvents { [weak self] granted, _ in
            DispatchQueue.main.async {
                self?.authorized = granted
                if granted { self?.refresh() }
            }
        }
    }

    func refresh() {
        guard authorized else { return }
        let now = Date()
        guard let end = Calendar.current.date(byAdding: .hour, value: 24, to: now) else { return }
        let predicate = store.predicateForEvents(withStart: now.addingTimeInterval(-3600), end: end, calendars: nil)
        let event = store.events(matching: predicate)
            .filter { !$0.isAllDay && $0.endDate > now }
            .sorted { $0.startDate < $1.startDate }
            .first

        let info = event.map {
            EventInfo(id: $0.eventIdentifier ?? UUID().uuidString,
                      title: $0.title ?? "Без названия",
                      start: $0.startDate,
                      end: $0.endDate,
                      color: Color(nsColor: $0.calendar.color),
                      location: $0.location)
        }
        if nextEvent != info { nextEvent = info }

        if let info, AppSettings.shared.calendarReminders, !notified.contains(info.id) {
            let left = info.start.timeIntervalSince(now)
            if left > 0 && left <= 5 * 60 {
                notified.insert(info.id)
                onUpcoming?(info)
            }
        }
    }
}
