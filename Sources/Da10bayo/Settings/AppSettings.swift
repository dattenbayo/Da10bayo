import Foundation
import Combine

/// Все пользовательские настройки. Каждое свойство сразу сохраняется в UserDefaults
/// и публикует изменения, чтобы остров перерисовывался «на лету».
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    // MARK: Поведение
    @Published var openOnHover: Bool { didSet { save(openOnHover, "openOnHover") } }
    @Published var hoverDelay: Double { didSet { save(hoverDelay, "hoverDelay") } }
    @Published var closeOnLeave: Bool { didSet { save(closeOnLeave, "closeOnLeave") } }
    @Published var haptics: Bool { didSet { save(haptics, "haptics") } }
    @Published var gestures: Bool { didSet { save(gestures, "gestures") } }
    @Published var swipeTracks: Bool { didSet { save(swipeTracks, "swipeTracks") } }
    @Published var showMenuBarIcon: Bool { didSet { save(showMenuBarIcon, "showMenuBarIcon") } }

    // MARK: Внешний вид
    @Published var openWidth: Double { didSet { save(openWidth, "openWidth") } }
    @Published var openHeight: Double { didSet { save(openHeight, "openHeight") } }
    @Published var cornerRadius: Double { didSet { save(cornerRadius, "cornerRadius") } }
    @Published var showCompactMedia: Bool { didSet { save(showCompactMedia, "showCompactMedia") } }
    @Published var tintFromArtwork: Bool { didSet { save(tintFromArtwork, "tintFromArtwork") } }
    /// Все плееры через системное «Сейчас играет» (Яндекс Музыка, браузеры…).
    @Published var universalMedia: Bool { didSet { save(universalMedia, "universalMedia") } }


    // MARK: Активности
    @Published var chargingActivity: Bool { didSet { save(chargingActivity, "chargingActivity") } }
    @Published var bluetoothActivity: Bool { didSet { save(bluetoothActivity, "bluetoothActivity") } }
    @Published var calendarReminders: Bool { didSet { save(calendarReminders, "calendarReminders") } }
    @Published var timerSound: Bool { didSet { save(timerSound, "timerSound") } }

    // MARK: VPN
    /// Имя системной VPN-конфигурации (как в `scutil --nc list`). INCY регистрирует «incy».
    @Published var vpnName: String { didSet { save(vpnName, "vpnName") } }
    @Published var vpnActivity: Bool { didSet { save(vpnActivity, "vpnActivity") } }

    // MARK: Уведомления приложений
    @Published var appNotifications: Bool { didSet { save(appNotifications, "appNotifications") } }
    @Published var dockBadges: Bool { didSet { save(dockBadges, "dockBadges") } }
    @Published var mutedNotificationApps: [String] { didSet { save(mutedNotificationApps, "mutedNotificationApps") } }

    // MARK: Полка
    @Published var copyToShelf: Bool { didSet { save(copyToShelf, "copyToShelf") } }
    @Published var clearShelfOnQuit: Bool { didSet { save(clearShelfOnQuit, "clearShelfOnQuit") } }

    private init() {
        openOnHover = Self.bool("openOnHover", true)
        hoverDelay = Self.double("hoverDelay", 0.12)
        closeOnLeave = Self.bool("closeOnLeave", true)
        haptics = Self.bool("haptics", true)
        gestures = Self.bool("gestures", true)
        swipeTracks = Self.bool("swipeTracks", true)
        showMenuBarIcon = Self.bool("showMenuBarIcon", true)

        openWidth = Self.double("openWidth", 620)
        openHeight = Self.double("openHeight", 200)
        cornerRadius = Self.double("cornerRadius", 24)
        showCompactMedia = Self.bool("showCompactMedia", true)
        tintFromArtwork = Self.bool("tintFromArtwork", true)
        universalMedia = Self.bool("universalMedia", true)


        chargingActivity = Self.bool("chargingActivity", true)
        bluetoothActivity = Self.bool("bluetoothActivity", true)
        calendarReminders = Self.bool("calendarReminders", true)
        timerSound = Self.bool("timerSound", true)

        vpnName = UserDefaults.standard.string(forKey: "vpnName") ?? "incy"
        vpnActivity = Self.bool("vpnActivity", true)

        appNotifications = Self.bool("appNotifications", true)
        dockBadges = Self.bool("dockBadges", true)
        mutedNotificationApps = UserDefaults.standard.stringArray(forKey: "mutedNotificationApps") ?? []

        copyToShelf = Self.bool("copyToShelf", false)
        clearShelfOnQuit = Self.bool("clearShelfOnQuit", false)
    }

    func resetAppearance() {
        openWidth = 620
        openHeight = 200
        cornerRadius = 24
    }

    private func save(_ value: Any, _ key: String) {
        UserDefaults.standard.set(value, forKey: key)
    }

    private static func bool(_ key: String, _ def: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? def
    }

    private static func double(_ key: String, _ def: Double) -> Double {
        UserDefaults.standard.object(forKey: key) as? Double ?? def
    }
}

extension Notification.Name {
    static let d10Preview = Notification.Name("da10bayo.preview")
    static let d10TestBanner = Notification.Name("da10bayo.testBanner")
}
