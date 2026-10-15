import Foundation

/// Таймер, который отображается live activity в вырезе.
final class TimerService: ObservableObject {
    @Published private(set) var endDate: Date?
    @Published private(set) var total: TimeInterval = 0

    var onFinish: (() -> Void)?
    private var ticker: Timer?

    var isRunning: Bool { endDate != nil }

    func start(minutes: Double) {
        total = minutes * 60
        endDate = Date().addingTimeInterval(total)
        ticker?.invalidate()
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        ticker = t
    }

    func add(minutes: Double) {
        guard let endDate else { return }
        self.endDate = endDate.addingTimeInterval(minutes * 60)
        total += minutes * 60
    }

    func stop() {
        ticker?.invalidate()
        ticker = nil
        endDate = nil
    }

    func remaining(at date: Date) -> TimeInterval {
        guard let endDate else { return 0 }
        return max(0, endDate.timeIntervalSince(date))
    }

    func progress(at date: Date) -> Double {
        guard total > 0 else { return 0 }
        return 1 - remaining(at: date) / total
    }

    private func tick() {
        if let endDate, endDate <= Date() {
            stop()
            onFinish?()
        }
    }
}
