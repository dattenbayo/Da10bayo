import AppKit
import SwiftUI
import Combine
import ApplicationServices
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = AppSettings.shared

    private let media = MediaService()
    private let shelf = ShelfStore()
    private let timer = TimerService()
    private let battery = BatteryMonitor()
    private let calendar = CalendarService()
    private let bluetooth = BluetoothMonitor()
    private let appNotifications = AppNotificationService()
    private let claude = ClaudeService()
    private let vpn = VPNService()
    private lazy var converter = FileConverter(fallbackDirectory: shelf.directory)

    private var vm: NotchViewModel!
    private var notch: NotchController!
    private var statusItem: NSStatusItem?
    private lazy var settingsWindow = SettingsWindowController(claude: claude, vpn: vpn)
    private var bag = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        vm = NotchViewModel(media: media, shelf: shelf, timer: timer, battery: battery, calendar: calendar,
                            converter: converter, notifications: appNotifications, claude: claude,
                            vpn: vpn)
        vm.onOpenSettings = { [weak self] in self?.openSettings() }
        notch = NotchController(vm: vm, media: media)

        media.start()
        battery.start()
        calendar.start()

        requestAccessibilityIfNeeded()
        setupActivities()
        setupStatusItem()
        enableLaunchAtLoginOnce()

        settings.$universalMedia.dropFirst().removeDuplicates()
            .sink { [weak self] on in DispatchQueue.main.async { self?.media.setUniversal(on) } }
            .store(in: &bag)
        settings.$showMenuBarIcon.dropFirst()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.setupStatusItem() } }
            .store(in: &bag)

        NotificationCenter.default.addObserver(forName: .d10Preview, object: nil, queue: .main) { [weak self] _ in
            self?.vm.openTemporarily()
        }
        NotificationCenter.default.addObserver(forName: .d10TestBanner, object: nil, queue: .main) { [weak self] _ in
            self?.vm.showBanner(Banner(symbol: "sparkles", tint: .purple, title: "Привет от Da10bayo", subtitle: "Так выглядят уведомления"))
        }
        #if DEBUG
        installDebugHooks()
        #endif
    }

    #if DEBUG
    /// Отладка: `swift build` + запуск бинарника, затем из терминала
    /// дёргаем состояния острова, не трогая зарядку и т. п.:
    /// osascript -l JavaScript -e '$.NSDistributedNotificationCenter.defaultCenter.postNotificationNameObjectUserInfoDeliverImmediately("da10bayo.debug", "power", $(), true)'
    private func installDebugHooks() {
        debugActivity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep], reason: "debug hooks")
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(debugCommand(_:)),
                                                            name: Notification.Name("da10bayo.debug"), object: nil,
                                                            suspensionBehavior: .deliverImmediately)
    }

    private var debugActivity: NSObjectProtocol?

    @objc private func debugCommand(_ note: Notification) {
        do {
            switch note.object as? String {
            case "power": self.vm.showPower(level: 12, plugged: true)
            case "banner":
                self.vm.showBanner(Banner(symbol: "bell.fill", tint: .white, title: "Иван", subtitle: "Привет! Ты видел новое видео?",
                                          icon: AppNotificationService.icon(for: "ru.keepcoder.Telegram"), bundleID: "ru.keepcoder.Telegram"), duration: 4.5)
            case "claudetab": self.vm.isPinned = true; self.vm.open(tab: .claude)
            case "acttab": self.vm.isPinned = true; self.vm.open(tab: .activities)
            case "vpnstrip": self.vm.showVPN(on: true)
            case "vpntoggle": self.vpn.toggle()
            case "open": self.vm.openTemporarily(tab: .home)
            case "drag": self.vm.debugHoldDrag = true; self.vm.beginFileDrag(); self.vm.hoveredDropTarget = .convert
            case "dragend": self.vm.debugHoldDrag = false; self.vm.endFileDrag()
            case "notifications": self.vm.openTemporarily(tab: .notifications)
            case "close": self.vm.close()
            case "track": self.media.debugFakeTrack()
            case "hover": self.vm.hoveredDropTarget = .airdrop
            case let cmd? where cmd.hasPrefix("convui:"):
                self.vm.isPinned = true
                self.converter.load(URL(fileURLWithPath: String(cmd.dropFirst(7))))
                self.vm.showConverter = true
                self.vm.open()
            case let cmd? where cmd.hasPrefix("conv:"):
                // conv:<путь>|<расширение>
                let parts = cmd.dropFirst(5).split(separator: "|").map(String.init)
                self.converter.load(URL(fileURLWithPath: parts[0]))
                if let f = self.converter.formats.first(where: { $0.ext == parts[1] }) { self.converter.convert(to: f) }
            case let cmd? where cmd.hasPrefix("dump:"):
                let info = "notch=\(self.vm.notchSize) island=\(self.vm.islandSize) open=\(self.vm.isOpen) drag=\(self.vm.isFileDragActive) peek=\(String(describing: self.vm.peek)) hovered=\(String(describing: self.vm.hoveredDropTarget)) statusAppearance=\(self.statusItem?.button?.effectiveAppearance.name.rawValue ?? "nil")\n"
                try? info.write(toFile: String(cmd.dropFirst(5)), atomically: true, encoding: .utf8)
            case let cmd? where cmd.hasPrefix("film"):
                // filmopen:<папка> / filmclose:<папка> — 30 кадров/с в течение 0.9 с
                let parts = cmd.split(separator: ":", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { break }
                if parts[0] == "filmopen" { self.vm.isPinned = true; self.vm.open(tab: .home) } else { self.vm.isPinned = false; self.vm.close() }
                for i in 0..<27 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) / 30) {
                        self.notch.snapshot(to: String(format: "%@/f%02d.png", parts[1], i))
                    }
                }
            case let cmd? where cmd.hasPrefix("snap:"): self.notch.snapshot(to: String(cmd.dropFirst(5)))
            default: break
            }
        }
    }
    #endif

    func applicationWillTerminate(_ notification: Notification) {
        if settings.clearShelfOnQuit { shelf.clear() }
    }

    // MARK: - Разрешение «Универсальный доступ»

    /// Нужно, чтобы читать уведомления других приложений. Спрашиваем один раз при запуске.
    private func requestAccessibilityIfNeeded() {
        guard settings.appNotifications, !AXIsProcessTrusted() else { return }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    // MARK: - Активности

    private func setupActivities() {
        battery.onPowerChange = { [weak self] plugged, level in
            guard let self, self.settings.chargingActivity else { return }
            self.vm.showPower(level: level, plugged: plugged)
        }
        battery.onLow = { [weak self] level in
            guard let self, self.settings.chargingActivity else { return }
            self.vm.showBanner(Banner(symbol: "battery.25percent", tint: .red, title: "Низкий заряд", subtitle: "Осталось \(level)%"), duration: 5)
        }

        bluetooth.onConnect = { [weak self] name, symbol in
            guard let self, self.settings.bluetoothActivity else { return }
            self.vm.showBanner(Banner(symbol: symbol, tint: .blue, title: name, subtitle: "Подключено"))
        }
        bluetooth.onDisconnect = { [weak self] name, symbol in
            guard let self, self.settings.bluetoothActivity else { return }
            self.vm.showBanner(Banner(symbol: symbol, tint: .gray, title: name, subtitle: "Отключено"), duration: 2.5)
        }
        bluetooth.start()

        calendar.onUpcoming = { [weak self] event in
            self?.vm.showBanner(Banner(symbol: "calendar", tint: event.color, title: event.title, subtitle: "Начнётся через 5 минут"), duration: 6)
        }

        appNotifications.onNotification = { [weak self] n in
            self?.vm.showBanner(Banner(symbol: "bell.fill", tint: .white, title: n.title,
                                       subtitle: n.body ?? n.appName, icon: n.icon, bundleID: n.bundleID),
                                duration: 4.5)
        }
        appNotifications.start()

        converter.onFinished = { [weak self] url in
            guard let self, url.path.hasPrefix(self.shelf.directory.path) else { return }
            self.shelf.add(url)
        }

        vpn.onChange = { [weak self] on in
            guard let self, self.settings.vpnActivity else { return }
            self.vm.showVPN(on: on)
        }
        vpn.start()
        settings.$vpnName.dropFirst().removeDuplicates()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.vpn.refreshConfigs() } }
            .store(in: &bag)

        timer.onFinish = { [weak self] in
            guard let self else { return }
            self.vm.showBanner(Banner(symbol: "timer", tint: .orange, title: "Таймер завершён", subtitle: nil), duration: 5)
            if self.settings.timerSound { NSSound(named: "Glass")?.play() }
        }
    }

    // MARK: - Автозапуск

    /// При первом запуске из /Applications включаем «Запускать при входе в систему».
    /// Дальше пользователь управляет этим переключателем в настройках.
    private func enableLaunchAtLoginOnce() {
        let key = "didSetupLaunchAtLogin"
        guard !UserDefaults.standard.bool(forKey: key),
              Bundle.main.bundlePath.hasPrefix("/Applications/") else { return }
        do {
            if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
            UserDefaults.standard.set(true, forKey: key)
        } catch {
            NSLog("Da10bayo: не удалось включить автозапуск: \(error)")
        }
    }

    // MARK: - Строка меню

    private func setupStatusItem() {
        if settings.showMenuBarIcon {
            guard statusItem == nil else { return }
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            item.button?.image = NSImage(systemSymbolName: "capsule.fill", accessibilityDescription: "Da10bayo")
            let menu = NSMenu()
            menu.addItem(withTitle: "Открыть остров", action: #selector(openIsland), keyEquivalent: "")
            menu.addItem(withTitle: "Полка", action: #selector(openShelf), keyEquivalent: "")
            menu.addItem(.separator())
            menu.addItem(withTitle: "Настройки…", action: #selector(openSettings), keyEquivalent: ",")
            menu.addItem(.separator())
            menu.addItem(withTitle: "Выйти из Da10bayo", action: #selector(quit), keyEquivalent: "q")
            menu.items.forEach { $0.target = self }
            item.menu = menu
            statusItem = item
        } else if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    @objc private func openIsland() { vm.openTemporarily(tab: .home) }

    @objc private func openShelf() { vm.openTemporarily(tab: .shelf) }

    @objc func openSettings() { settingsWindow.show() }

    @objc private func quit() { NSApp.terminate(nil) }
}
