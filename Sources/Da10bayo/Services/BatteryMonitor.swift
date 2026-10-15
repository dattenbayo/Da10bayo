import Foundation
import IOKit.ps

/// Состояние батареи и события «подключено к питанию / низкий заряд».
final class BatteryMonitor: ObservableObject {
    struct State: Equatable {
        var level: Int
        var isCharging: Bool
        var isPluggedIn: Bool
        var minutesToFull: Int?
        var minutesToEmpty: Int?

        var symbol: String {
            if isCharging || isPluggedIn { return "battery.100percent.bolt" }
            switch level {
            case 88...: return "battery.100percent"
            case 63..<88: return "battery.75percent"
            case 38..<63: return "battery.50percent"
            case 13..<38: return "battery.25percent"
            default: return "battery.0percent"
            }
        }

        var statusText: String {
            if isCharging {
                if let m = minutesToFull { return "Заряжается · ещё \(Self.duration(m))" }
                return "Заряжается"
            }
            if isPluggedIn { return "Подключено к питанию" }
            if let m = minutesToEmpty { return "От батареи · \(Self.duration(m))" }
            return "От батареи"
        }

        static func duration(_ minutes: Int) -> String {
            minutes >= 60 ? "\(minutes / 60) ч \(minutes % 60) мин" : "\(minutes) мин"
        }
    }

    @Published private(set) var state: State?

    var onPowerChange: ((Bool, Int) -> Void)?
    var onLow: ((Int) -> Void)?

    private var source: CFRunLoopSource?
    private var warned: Set<Int> = []

    func start() {
        state = Self.read()
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        if let src = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            Unmanaged<BatteryMonitor>.fromOpaque(ctx).takeUnretainedValue().update()
        }, ctx)?.takeRetainedValue() {
            source = src
            CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        }
    }

    private func update() {
        let old = state
        guard let new = Self.read() else { return }
        state = new

        if let old, old.isPluggedIn != new.isPluggedIn {
            onPowerChange?(new.isPluggedIn, new.level)
        }
        if new.isPluggedIn {
            warned.removeAll()
        } else {
            for threshold in [20, 10] where new.level <= threshold && !warned.contains(threshold) {
                warned.insert(threshold)
                onLow?(new.level)
                break
            }
        }
    }

    static func read() -> State? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as NSArray? else { return nil }

        for ps in list {
            let ref = ps as CFTypeRef
            guard let desc = IOPSGetPowerSourceDescription(info, ref)?.takeUnretainedValue() as? [String: Any],
                  (desc[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType else { continue }

            let current = desc[kIOPSCurrentCapacityKey] as? Int ?? 0
            let maximum = desc[kIOPSMaxCapacityKey] as? Int ?? 100
            let level = maximum > 0 ? Int((Double(current) / Double(maximum) * 100).rounded()) : current
            let charging = desc[kIOPSIsChargingKey] as? Bool ?? false
            let plugged = (desc[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
            let toFull = desc[kIOPSTimeToFullChargeKey] as? Int ?? -1
            let toEmpty = desc[kIOPSTimeToEmptyKey] as? Int ?? -1

            return State(level: level,
                         isCharging: charging,
                         isPluggedIn: plugged,
                         minutesToFull: toFull > 0 ? toFull : nil,
                         minutesToEmpty: toEmpty > 0 ? toEmpty : nil)
        }
        return nil
    }
}
