import AppKit
import ApplicationServices
import os

struct AppNotification: Identifiable, Equatable {
    let id = UUID()
    var bundleID: String?
    var appName: String
    var title: String
    var body: String?
    var date = Date()

    var icon: NSImage? { AppNotificationService.icon(for: bundleID) }
}

/// Уведомления других приложений (Telegram, WhatsApp, Почта, Slack…).
/// macOS не даёт сторонним программам подписаться на чужие уведомления, поэтому
/// используем то, что открывает разрешение «Универсальный доступ»:
///   1) баннеры Центра уведомлений — читаем их текст через Accessibility;
///   2) бейджи на иконках в Dock — если баннеры отключены, видно хотя бы «+3 в Telegram».
final class AppNotificationService: ObservableObject {
    @Published private(set) var items: [AppNotification] = []
    /// Выдан ли «Универсальный доступ» — обновляется на лету, без перезапуска.
    @Published private(set) var trusted = AXIsProcessTrusted()

    var onNotification: ((AppNotification) -> Void)?

    private let settings = AppSettings.shared
    private var timer: Timer?
    private var badges: [String: Int] = [:]
    private var badgesPrimed = false
    private var seenBanners: [String: Date] = [:]
    private var lastBannerFrom: [String: Date] = [:]

    private static let notificationCenterID = "com.apple.notificationcenterui"
    private static let dockID = "com.apple.dock"

    func start() {
        log.notice("Старт: доступ \(self.trusted ? "выдан" : "нет", privacy: .public), уведомления приложений \(self.settings.appNotifications ? "вкл" : "выкл", privacy: .public)")
        let t = Timer(timeInterval: 0.7, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func clear() { items.removeAll() }

    func remove(_ item: AppNotification) { items.removeAll { $0.id == item.id } }

    static func openApp(_ bundleID: String) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    static func icon(for bundleID: String?) -> NSImage? {
        guard let bundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    // MARK: - Опрос

    private var tickCount = 0
    private let log = Logger(subsystem: "com.da10bayo.app", category: "notifications")
    private var lastStructure = ""

    private func tick() {
        let isTrusted = AXIsProcessTrusted()
        if isTrusted != trusted {
            trusted = isTrusted
            log.notice("Универсальный доступ: \(isTrusted ? "выдан" : "нет", privacy: .public)")
        }
        guard settings.appNotifications, isTrusted else { return }
        scanNotificationCenter()
        tickCount += 1
        if settings.dockBadges && tickCount % 3 == 0 { scanDock() }
    }

    // MARK: - Баннеры Центра уведомлений

    private func scanNotificationCenter() {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: Self.notificationCenterID).first else { return }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        let windows: [AXUIElement] = Self.attribute(root, kAXWindowsAttribute) ?? []
        guard !windows.isEmpty else { return }

        var found: [(desc: String, texts: [String])] = []
        for window in windows { collectBanners(window, depth: 0, into: &found) }

        // Диагностика: какие роли/подроли видим в окнах Центра уведомлений (без текста).
        var roles: [String] = []
        for window in windows { collectRoles(window, depth: 0, into: &roles) }
        let structure = roles.joined(separator: ",")
        if structure != lastStructure {
            lastStructure = structure
            log.notice("Центр уведомлений: окон \(windows.count), баннеров \(found.count), роли: \(structure, privacy: .public)")
        }

        let now = Date()
        seenBanners = seenBanners.filter { now.timeIntervalSince($0.value) < 60 }
        for banner in found {
            let key = ([banner.desc] + banner.texts).joined(separator: "|")
            guard seenBanners[key] == nil else { continue }
            seenBanners[key] = now
            if let n = makeNotification(desc: banner.desc, texts: banner.texts) { deliver(n) }
        }
    }

    /// Ищем группы-баннеры: у них подроль вида AXNotificationCenter* или описание с текстом.
    private func collectBanners(_ element: AXUIElement, depth: Int, into result: inout [(desc: String, texts: [String])]) {
        guard depth < 9 else { return }
        let subrole: String = Self.attribute(element, kAXSubroleAttribute) ?? ""
        if subrole.hasPrefix("AXNotificationCenter") && subrole != "AXNotificationCenterAlertStack" {
            var texts: [String] = []
            collectTexts(element, depth: 0, into: &texts)
            let desc: String = Self.attribute(element, kAXDescriptionAttribute) ?? ""
            if !texts.isEmpty || !desc.isEmpty { result.append((desc, texts)) }
            return
        }
        let children: [AXUIElement] = Self.attribute(element, kAXChildrenAttribute) ?? []
        for child in children { collectBanners(child, depth: depth + 1, into: &result) }
    }

    private func collectRoles(_ element: AXUIElement, depth: Int, into roles: inout [String]) {
        guard depth < 8, roles.count < 60 else { return }
        let role: String = Self.attribute(element, kAXRoleAttribute) ?? "?"
        let sub: String = Self.attribute(element, kAXSubroleAttribute) ?? ""
        if role != kAXStaticTextRole as String { roles.append(sub.isEmpty ? role : "\(role)/\(sub)") }
        let children: [AXUIElement] = Self.attribute(element, kAXChildrenAttribute) ?? []
        for child in children { collectRoles(child, depth: depth + 1, into: &roles) }
    }

    private func collectTexts(_ element: AXUIElement, depth: Int, into texts: inout [String]) {
        guard depth < 6 else { return }
        let role: String = Self.attribute(element, kAXRoleAttribute) ?? ""
        if role == kAXStaticTextRole as String,
           let value: String = Self.attribute(element, kAXValueAttribute),
           !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            texts.append(value)
        }
        let children: [AXUIElement] = Self.attribute(element, kAXChildrenAttribute) ?? []
        for child in children { collectTexts(child, depth: depth + 1, into: &texts) }
    }

    private func makeNotification(desc: String, texts: [String]) -> AppNotification? {
        // Описание баннера обычно начинается с имени приложения: «Telegram, Иван, привет».
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        let haystack = ([desc] + texts).joined(separator: ", ")
        let app = apps
            .filter { app in app.localizedName.map { haystack.localizedCaseInsensitiveContains($0) } ?? false }
            .max { ($0.localizedName?.count ?? 0) < ($1.localizedName?.count ?? 0) }

        var lines = texts
        if lines.isEmpty {
            lines = desc.components(separatedBy: ", ")
        }
        if let name = app?.localizedName, lines.first?.caseInsensitiveCompare(name) == .orderedSame, lines.count > 1 {
            lines.removeFirst()
        }
        // Отбрасываем служебные подписи вроде «сейчас», «2 мин назад».
        lines = lines.filter { !Self.isTimestamp($0) }
        guard let title = lines.first else { return nil }
        let body = lines.dropFirst().joined(separator: " ")
        return AppNotification(bundleID: app?.bundleIdentifier,
                               appName: app?.localizedName ?? "Уведомление",
                               title: title,
                               body: body.isEmpty ? nil : body)
    }

    private static func isTimestamp(_ s: String) -> Bool {
        let lower = s.lowercased()
        return ["сейчас", "now", "назад", "ago"].contains { lower == $0 || lower.hasSuffix(" " + $0) }
    }

    // MARK: - Бейджи в Dock

    private func scanDock() {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: Self.dockID).first else { return }
        let root = AXUIElementCreateApplication(dock.processIdentifier)
        var current: [String: Int] = [:]
        var names: [String: String] = [:]

        let lists: [AXUIElement] = Self.attribute(root, kAXChildrenAttribute) ?? []
        for list in lists {
            let items: [AXUIElement] = Self.attribute(list, kAXChildrenAttribute) ?? []
            for item in items {
                guard let url: URL = Self.attribute(item, kAXURLAttribute),
                      let bundle = Bundle(url: url)?.bundleIdentifier else { continue }
                let label: String = Self.attribute(item, "AXStatusLabel") ?? ""
                let count = Int(label.filter(\.isNumber)) ?? (label.isEmpty ? 0 : 1)
                current[bundle] = count
                names[bundle] = Self.attribute(item, kAXTitleAttribute) ?? url.deletingPathExtension().lastPathComponent
            }
        }

        defer { badges = current; badgesPrimed = true }
        guard badgesPrimed else { return }

        for (bundle, count) in current where count > (badges[bundle] ?? 0) {
            // Баннер этого приложения уже показали — бейдж не дублируем.
            if let last = lastBannerFrom[bundle], Date().timeIntervalSince(last) < 8 { continue }
            let added = count - (badges[bundle] ?? 0)
            let name = names[bundle] ?? bundle
            deliver(AppNotification(bundleID: bundle, appName: name, title: name,
                                    body: Self.newMessagesText(added, total: count)))
        }
    }

    static func newMessagesText(_ added: Int, total: Int) -> String {
        let mod10 = added % 10, mod100 = added % 100
        let word: String
        if mod10 == 1 && mod100 != 11 { word = "новое уведомление" }
        else if (2...4).contains(mod10) && !(12...14).contains(mod100) { word = "новых уведомления" }
        else { word = "новых уведомлений" }
        return "\(added) \(word) · всего \(total)"
    }

    // MARK: - Доставка

    private func deliver(_ n: AppNotification) {
        if let id = n.bundleID {
            if settings.mutedNotificationApps.contains(id) { return }
            lastBannerFrom[id] = Date()
        }
        log.notice("Уведомление от \(n.bundleID ?? "?", privacy: .public)")
        items.insert(n, at: 0)
        if items.count > 30 { items.removeLast(items.count - 30) }
        onNotification?(n)
    }

    // MARK: - AX

    private static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success, let value else { return nil }
        if T.self == URL.self, let url = value as? NSURL { return url as URL as? T }
        return value as? T
    }
}
