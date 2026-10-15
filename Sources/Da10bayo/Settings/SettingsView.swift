import SwiftUI
import Combine
import ServiceManagement
import ApplicationServices

final class SettingsWindowController: NSWindowController {
    convenience init(claude: ClaudeService, vpn: VPNService) {
        let hosting = NSHostingController(rootView: SettingsView(claude: claude, vpn: vpn))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Настройки Da10bayo"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.center()
        self.init(window: window)
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    @ObservedObject var settings = AppSettings.shared
    let claude: ClaudeService
    let vpn: VPNService

    var body: some View {
        TabView {
            GeneralSettings(settings: settings)
                .tabItem { Label("Основные", systemImage: "gearshape") }
            AppearanceSettings(settings: settings)
                .tabItem { Label("Вид", systemImage: "paintbrush") }
            AccessSettings()
                .tabItem { Label("Доступ", systemImage: "lock.shield") }
            ActivitySettings(settings: settings, vpn: vpn)
                .tabItem { Label("Активности", systemImage: "bolt") }
            ShelfSettings(settings: settings)
                .tabItem { Label("Полка", systemImage: "tray") }
            ClaudeSettings(claude: claude)
                .tabItem { Label("Claude", systemImage: "sparkle") }
            AboutView()
                .tabItem { Label("О программе", systemImage: "info.circle") }
        }
        .frame(width: 560, height: 440)
    }
}

private struct ValueSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 1
    var format: String = "%.0f"

    var body: some View {
        LabeledContent(title) {
            HStack {
                Slider(value: $value, in: range, step: step)
                Text(String(format: format, value))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 52, alignment: .trailing)
            }
            .frame(width: 280)
        }
    }
}

struct GeneralSettings: View {
    @ObservedObject var settings: AppSettings
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Section {
                Toggle("Запускать при входе в систему", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do {
                            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
                Toggle("Показывать иконку в строке меню", isOn: $settings.showMenuBarIcon)
            }
            Section("Поведение") {
                Toggle("Открывать при наведении", isOn: $settings.openOnHover)
                if settings.openOnHover {
                    ValueSlider(title: "Задержка", value: $settings.hoverDelay, range: 0...0.6, step: 0.02, format: "%.2f с")
                }
                Toggle("Закрывать, когда курсор уходит", isOn: $settings.closeOnLeave)
                Toggle("Тактильный отклик трекпада", isOn: $settings.haptics)
            }
            Section {
                Toggle("Жесты на острове", isOn: $settings.gestures)
                Toggle("Свайп влево / вправо переключает трек", isOn: $settings.swipeTracks)
                    .disabled(!settings.gestures)
            } header: {
                Text("Жесты")
            } footer: {
                Text("Два пальца вниз над вырезом — открыть, вверх — закрыть.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct AppearanceSettings: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Section("Раскрытый остров") {
                ValueSlider(title: "Ширина", value: $settings.openWidth, range: 520...820, step: 10)
                ValueSlider(title: "Высота", value: $settings.openHeight, range: 170...280, step: 5)
                ValueSlider(title: "Скругление углов", value: $settings.cornerRadius, range: 10...36, step: 1)
                HStack {
                    Button("Показать") { NotificationCenter.default.post(name: .d10Preview, object: nil) }
                    Button("Сбросить") { settings.resetAppearance() }
                }
            }
            Section("Музыка") {
                Toggle("Обложка и эквалайзер в свёрнутом острове", isOn: $settings.showCompactMedia)
                Toggle("Подсвечивать цветом обложки", isOn: $settings.tintFromArtwork)
                Toggle("Все плееры: Яндекс Музыка, браузеры, VLC…", isOn: $settings.universalMedia)
                    .help("Через системное «Сейчас играет». Spotify и Apple Music читаются напрямую — там доступны перемешивание и избранное.")
            }
        }
        .formStyle(.grouped)
    }
}

struct AccessSettings: View {
    @State private var trusted = AXIsProcessTrusted()
    private let poll = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section("Разрешение") {
                LabeledContent("Универсальный доступ") {
                    HStack {
                        Image(systemName: trusted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(trusted ? Color.green : Color.orange)
                        Text(trusted ? "Выдано" : "Не выдано")
                    }
                }
                Text("Нужно, чтобы показывать в острове уведомления Telegram и других приложений.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if !trusted {
                    Button("Открыть настройки конфиденциальности") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onReceive(poll) { _ in trusted = AXIsProcessTrusted() }
    }
}

struct ActivitySettings: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var vpn: VPNService

    var body: some View {
        Form {
            Section {
                if vpn.configs.isEmpty {
                    LabeledContent("Конфигурация") { Text("VPN не найден").foregroundStyle(.secondary) }
                } else {
                    Picker("Конфигурация", selection: $settings.vpnName) {
                        ForEach(vpn.configs) { config in
                            Text(config.provider.isEmpty ? config.name : "\(config.name) (\(config.provider))")
                                .tag(config.name)
                        }
                    }
                }
                LabeledContent("Состояние") { Text(vpn.status.title) }
                Toggle("Показывать полосу при включении и выключении", isOn: $settings.vpnActivity)
            } header: {
                Text("VPN")
            } footer: {
                Text("Кнопка-щит в шапке острова и карточка во вкладке «Активности» включают и выключают VPN "
                     + "через системную конфигурацию — так же, как переключатель в «Системных настройках».")
                    .foregroundStyle(.secondary)
            }
            .onAppear { vpn.refreshConfigs() }
            Section("Live activities и уведомления") {
                Toggle("Подключение и отключение зарядки", isOn: $settings.chargingActivity)
                Toggle("Подключение Bluetooth-устройств (AirPods и др.)", isOn: $settings.bluetoothActivity)
                Toggle("Напоминание о событии календаря за 5 минут", isOn: $settings.calendarReminders)
                Toggle("Звук по окончании таймера", isOn: $settings.timerSound)
            }
            Section {
                Toggle("Уведомления приложений (Telegram, почта, мессенджеры…)", isOn: $settings.appNotifications)
                Toggle("Следить за бейджами на иконках в Dock", isOn: $settings.dockBadges)
                    .disabled(!settings.appNotifications)
                if !settings.mutedNotificationApps.isEmpty {
                    LabeledContent("Без уведомлений") {
                        HStack {
                            Text(settings.mutedNotificationApps.map(Self.appName).joined(separator: ", "))
                                .lineLimit(2)
                            Button("Сбросить") { settings.mutedNotificationApps = [] }
                        }
                    }
                }
            } header: {
                Text("Другие приложения")
            } footer: {
                Text("Нужен «Универсальный доступ»: Da10bayo читает текст баннеров Центра уведомлений и бейджи в Dock. "
                     + "Чтобы видеть уведомление только в острове, в «Системных настройках → Уведомления» выберите для приложения стиль «Временно» — "
                     + "или «Нет» (тогда придёт только счётчик из бейджа). Отключить приложение — правый клик по уведомлению на вкладке «Уведомления».")
                    .foregroundStyle(.secondary)
            }
            Section {
                Button("Показать тестовое уведомление") {
                    NotificationCenter.default.post(name: .d10TestBanner, object: nil)
                }
            }
        }
        .formStyle(.grouped)
    }

    static func appName(_ bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }
}

struct ClaudeSettings: View {
    @ObservedObject var claude: ClaudeService
    @State private var key = ""

    var body: some View {
        Form {
            Section {
                LabeledContent("Ключ API") {
                    HStack {
                        Image(systemName: claude.hasKey ? "checkmark.circle.fill" : "circle.dashed")
                            .foregroundStyle(claude.hasKey ? Color.green : Color.secondary)
                        Text(claude.hasKey ? "Сохранён в Связке ключей" : "Не задан")
                    }
                }
                SecureField("sk-ant-…", text: $key)
                HStack {
                    Button("Сохранить") { claude.saveKey(key); key = "" }
                        .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty)
                    if claude.hasKey {
                        Button("Удалить ключ", role: .destructive) { claude.saveKey("") }
                    }
                    Spacer()
                    Link("Получить ключ", destination: URL(string: "https://console.anthropic.com/settings/keys")!)
                }
            } header: {
                Text("Ответы прямо в острове")
            } footer: {
                Text("С ключом вопрос из вкладки ✦ уходит в Claude Opus 5.5, ответ появляется в острове. "
                     + "Запросы оплачиваются по тарифу Anthropic API. Без ключа вопрос копируется "
                     + "в буфер обмена и открывается приложение Claude.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct ShelfSettings: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Section {
                Toggle("Копировать файлы на полку", isOn: $settings.copyToShelf)
                Toggle("Очищать полку при выходе", isOn: $settings.clearShelfOnQuit)
            } footer: {
                Text("Без копирования полка хранит только ссылку на файл. Временные файлы (например, превью скриншотов) копируются всегда.")
                    .foregroundStyle(.secondary)
            }
            Section {
                Button("Открыть папку полки") {
                    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                    NSWorkspace.shared.open(base.appendingPathComponent("Da10bayo/Shelf", isDirectory: true))
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct AboutView: View {
    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
            Text("Da10bayo")
                .font(.system(size: 22, weight: .bold))
            Text("Версия \(version)")
                .foregroundStyle(.secondary)
            Text("Dynamic Island для выреза вашего Mac: музыка, Claude, уведомления, live activities и полка для файлов.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
